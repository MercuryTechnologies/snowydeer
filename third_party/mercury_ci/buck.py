# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Validated parsing of canonical absolute Buck target labels."""

from dataclasses import dataclass
import dataclasses
from pathlib import Path


def _reject_bad_chars(field: str, value: str) -> None:
    for ch in value:
        if ch == "\0" or ch.isspace() or ord(ch) < 0x20 or ord(ch) == 0x7F:
            raise ValueError(f"{field} contains whitespace/control/NUL: {value!r}")


def _validate_package(package: str) -> None:
    # "" is the root package (`//:name`). A non-empty package must have no empty,
    # `.`, or `..` segments, so a label can never traverse out of its package.
    # `:` is also forbidden because it is the package/name delimiter in `__str__`.
    if package == "":
        return
    if ":" in package:
        raise ValueError(f"package must not contain `:`: {package!r}")
    for segment in package.split("/"):
        if segment in ("", ".", ".."):
            raise ValueError(f"invalid package segment in {package!r}")


@dataclass(frozen=True, slots=True)
class BuckTarget:
    """A canonical absolute Buck label `[cell]//package:name`.

    `cell` is `None` for a cell-relative `//package:name`. Fields are validated
    on construction, so a `BuckTarget` is always well-formed. The wide
    punctuation Buck allows in target names is preserved; callers needing a
    narrower name policy impose it themselves.
    """

    cell: str | None
    package: str
    name: str

    def __post_init__(self) -> None:
        if self.cell is not None:
            if not self.cell:
                raise ValueError("cell must be a non-empty string or None")
            _reject_bad_chars("cell", self.cell)
            if "/" in self.cell or ":" in self.cell:
                raise ValueError(f"cell must not contain `/` or `:`: {self.cell!r}")
        _reject_bad_chars("package", self.package)
        _validate_package(self.package)
        _reject_bad_chars("name", self.name)
        if not self.name:
            raise ValueError("target name must be non-empty")
        if ":" in self.name:
            raise ValueError(f"target name must not contain `:`: {self.name!r}")

    @classmethod
    def parse(cls, label: str) -> "BuckTarget":
        cell_part, sep, rest = label.partition("//")
        if not sep:
            raise ValueError(f"not an absolute Buck label (missing `//`): {label!r}")
        package, sep, name = rest.partition(":")
        if not sep:
            raise ValueError(f"Buck label is missing `:name`: {label!r}")
        return cls(cell=cell_part or None, package=package, name=name)

    @classmethod
    def parse_configured(cls, label: str) -> "BuckTarget":
        """Parse Buck cquery's `<label> (<configuration>)` representation."""
        unconfigured, _separator, _configuration = label.partition(" (")
        return cls.parse(unconfigured)

    def __str__(self) -> str:
        return f"{self.cell or ''}//{self.package}:{self.name}"


@dataclass(frozen=True, slots=True)
class BuckPackagePattern:
    """A named-cell Buck package pattern, exact (`cell//pkg:`) or recursive."""

    cell: str
    package: str
    recursive: bool

    def __post_init__(self) -> None:
        if not self.cell:
            raise ValueError("package pattern cell must be non-empty")
        _reject_bad_chars("cell", self.cell)
        if "/" in self.cell or ":" in self.cell:
            raise ValueError(
                f"package pattern cell must not contain `/` or `:`: {self.cell!r}"
            )
        _reject_bad_chars("package", self.package)
        _validate_package(self.package)

    @classmethod
    def parse(cls, pattern: str) -> "BuckPackagePattern":
        """Parse `cell//package:` or recursive `cell//package/...`."""
        cell, separator, package_pattern = pattern.partition("//")
        if not separator or not cell:
            raise ValueError(f"package pattern must use a named cell: {pattern!r}")
        if package_pattern == "...":
            return cls(cell, "", True)
        if package_pattern.endswith("/..."):
            return cls(cell, package_pattern.removesuffix("/..."), True)
        if package_pattern.endswith(":"):
            return cls(cell, package_pattern.removesuffix(":"), False)
        raise ValueError(f"package pattern must end in `:` or `/...`: {pattern!r}")

    def matches_package(self, cell: str | None, package: str) -> bool:
        """Return whether this pattern contains a package."""
        if cell != self.cell:
            return False
        if not self.recursive:
            return package == self.package
        return (
            not self.package
            or package == self.package
            or package.startswith(f"{self.package}/")
        )

    def matches(self, target: BuckTarget) -> bool:
        """Return whether this pattern contains a target."""
        return self.matches_package(target.cell, target.package)

    def __str__(self) -> str:
        if self.recursive:
            suffix = "..." if not self.package else f"{self.package}/..."
        else:
            suffix = f"{self.package}:"
        return f"{self.cell}//{suffix}"


@dataclasses.dataclass(frozen=True, slots=True)
class CellMap:
    """Buck cell names paired with repository-relative roots."""

    roots: list[tuple[str, Path]]

    @classmethod
    def parse(cls, output: str, repo: Path) -> "CellMap":
        cells: list[tuple[str, Path]] = []
        for line in output.splitlines():
            name, separator, raw_path = line.partition(": ")
            if not separator or not name or not raw_path:
                raise ValueError(f"malformed `buck2 audit cell` line: {line!r}")
            path = Path(raw_path)
            try:
                relative = path.resolve().relative_to(repo.resolve())
            except ValueError as error:
                raise ValueError(
                    f"cell {name!r} is outside the repository: {path}"
                ) from error
            cells.append((name, relative))
        if not any(path == Path(".") for _, path in cells):
            raise ValueError("cell map has no repository-root cell")
        return cls(sorted(cells, key=lambda item: len(item[1].parts), reverse=True))
