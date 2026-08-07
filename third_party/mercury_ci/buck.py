# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Validated parsing of canonical absolute Buck target labels."""

from dataclasses import dataclass


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

    def __str__(self) -> str:
        return f"{self.cell or ''}//{self.package}:{self.name}"
