# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

import dataclasses
import subprocess
import pathlib
import sys
import functools
import json
from collections.abc import Sequence
from dataclasses import dataclass
import os
import shlex
import itertools
import typing
from . import github


ANSI_CYAN = "\033[96m"
ANSI_RESET = "\033[0m"

StrOrPath = os.PathLike[str] | str


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    args: list[str]
    stdout: bytes
    stderr: bytes

    @classmethod
    def from_subprocess(
        cls, obj: subprocess.CompletedProcess[bytes]
    ) -> "CommandResult":
        return cls(
            args=obj.args,
            returncode=obj.returncode,
            stdout=obj.stdout or b"",
            stderr=obj.stderr or b"",
        )

    def ok(self) -> "CommandResult":
        """
        Requires that the process succeeded.

        :raises subprocess.CalledProcessError: if it did not
        """
        return self.expect(0)

    def expect(self, rc: int) -> "CommandResult":
        """
        Requires that the process produced the provided return code.

        :raises subprocess.CalledProcessError: if it did not
        """
        if self.returncode != rc:
            raise subprocess.CalledProcessError(
                returncode=self.returncode,
                cmd=self.args,
                output=self.stdout,
                stderr=self.stderr,
            )
        return self

    @property
    def stdout_s(self) -> str:
        """
        Gets the process stdout as a string.
        """
        return self.stdout.decode(errors="raise")

    @property
    def stdout_lines(self) -> list[str]:
        """Gets the lines of process stdout, with trailing newlines eaten"""
        return self.stdout_s.splitlines()

    @property
    def stderr_s(self) -> str:
        """
        Gets the process stderr as a string.
        """
        return self.stderr.decode(errors="raise")

    @property
    def stderr_lines(self) -> list[str]:
        """Gets the lines of process stderr, with trailing newlines eaten"""
        return self.stderr_s.splitlines()


class AbstractCiActions:
    """
    An abstract class defining the functionality provided by this library,
    allowing for easy mocking in case we write tests for these in the future.
    """

    def log(self, message: str):
        """
        Print a message to stderr.
        """
        raise NotImplementedError

    def run_subprocess(
        self,
        args: list[str],
        capture_output: bool = False,
        capture_err: bool = False,
        check: bool = True,
    ) -> CommandResult:
        """
        Run a subprocess. The subprocess runs inside `hotel exec`, which
        ensures that we get an otel span which includes handy attributes like
        the process exit code
        sent to Honeycomb.

        kwargs:
        - capture_output:
             By default, stdout and stderr both go to the console, but if this
             is set to True, stdout is captured and returned instead.

        - check:
             True by default; if false, allow the command to fail (i.e. exit
             nonzero)"""
        raise NotImplementedError

    def popen_subprocess(self, args: list[str], **kwargs) -> subprocess.Popen:
        """
        Similar to run_subprocess but does not wait for it, instead returning the
        Popen handle. Useful for running several commands concurrently.
        """
        raise NotImplementedError

    def run_buck2(
        self,
        args: list[str],
        capture_output: bool = False,
        capture_err: bool = False,
        check: bool = True,
        log_critical_path: bool = False,
    ) -> CommandResult:
        """
        Run buck2 via run_subprocess() and optionally also log the critical
        path afterwards.
        """
        raise NotImplementedError

    def touch_file(self, path: StrOrPath):
        """
        Create a file if it doesn't exist, or set its modified time to now if
        it does.
        """
        raise NotImplementedError

    def write_file(self, path: StrOrPath, content: str, print_content: bool = False):
        """
        Write a file at the given path with the given content (and log a
        message saying we've done so). If print_content=True, also log the
        content.
        """
        raise NotImplementedError

    def read_json_file(self, path: StrOrPath) -> typing.Any:
        """
        Parse JSON contained within the file at the given path.
        """
        raise NotImplementedError

    def write_github_output(self, name: str, value: str) -> None:
        """
        Writes a value to $GITHUB_OUTPUT.
        """
        raise NotImplementedError


class CiActions(AbstractCiActions):
    def log(self, message: str):
        print(f"{ANSI_CYAN}• {message}{ANSI_RESET}", file=sys.stderr)

    def _log_command(self, args: list[str]):
        if len(args) < 50:
            self.log(f"$ {shlex.join(args)}")
        else:
            self.log(f"$ {shlex.join(args[:50])} ...")

    def _hotel_wrapped(self, args: list[str]) -> list[str]:
        otel_attrs_args = []
        # Add an attribute if this is happening as part of a required check.
        # This allows us to vary our SLO across required/optional checks.
        if os.environ.get("CI_REQUIRED_CHECK", None):
            otel_attrs_args.append("--attribute")
            otel_attrs_args.append("ci_required_check=true")

        hotel = os.environ.get("HOTEL")
        if not hotel:
            raise ValueError(
                'Please set HOTEL to the hotel executable or if you really want to skip telemetry, set it to "skip"'
            )
        if hotel == "skip":
            return list(args)
        return [hotel, "exec"] + otel_attrs_args + args

    def run_subprocess(
        self, args: list[str], capture_output=False, capture_err=False, check=True
    ) -> CommandResult:
        kwargs: dict = {"check": check}
        if capture_output:
            kwargs["stdout"] = subprocess.PIPE
        if capture_err:
            kwargs["stderr"] = subprocess.PIPE

        self._log_command(args)
        return CommandResult.from_subprocess(
            subprocess.run(self._hotel_wrapped(args), **kwargs)
        )

    def popen_subprocess(self, args: list[str], **kwargs) -> subprocess.Popen:
        self._log_command(args)
        return subprocess.Popen(self._hotel_wrapped(args), **kwargs)

    @property
    def buck2(self) -> "Buck2":
        """
        Returns a friendly buck2 wrapper.
        """
        return Buck2(self)

    def run_buck2(
        self,
        args: list[str],
        capture_output=False,
        capture_err=False,
        check=True,
        log_critical_path=False,
    ) -> CommandResult:
        try:
            return self.run_subprocess(
                ["buck2", *args],
                capture_output=capture_output,
                capture_err=capture_err,
                check=check,
            )
        finally:
            if log_critical_path:
                print("::group::buck2 log critical-path", file=sys.stderr)
                critical_path_output = self.run_subprocess(
                    ["buck2", "log", "critical-path"], capture_output=True
                )
                print(critical_path_output.stdout_s, file=sys.stderr)
                print("::endgroup::", file=sys.stderr)

    def touch_file(self, path):
        with open(path, "a") as _f:
            pass

    def write_file(self, path: StrOrPath, content: str, print_content=False):
        parent = pathlib.Path(path).parent
        if not parent.is_dir():
            parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        if print_content:
            self.log(f"Wrote {path} with content:")
            print(content, file=sys.stderr)
        else:
            self.log(f"Wrote {path}")

    def read_json_file(self, path: StrOrPath):
        with open(path) as f:
            content = f.read()
        return json.loads(content)

    def write_github_output(self, name: str, value: str) -> None:
        """
        Writes a value to $GITHUB_OUTPUT.
        """
        self.log(f"Set GITHUB_OUTPUT:\n  {name}={value}")
        if "GITHUB_OUTPUT" in os.environ:
            github.write_output(name, value)


class Flags(typing.Protocol):
    """
    A group of buck2 flags occupying the prefix between a subcommand and its
    first positional argument.

    Structural on purpose: the groups implementing this (`BuckOpts`,
    `TestFilters`) are unrelated to each other, and different subcommands
    accept different combinations of them.
    """

    def to_args(self) -> list[str]: ...


@dataclass(frozen=True)
class BuckOpts:
    """
    buck2's target-configuration flags: the prefix option group shared by
    `build`, `run`, `test` and the query commands.

    Only flags belonging to many commands go in this. Flags that just one
    subcommand takes (`--output-attribute`, the `TestFilters`) are parameters
    of that subcommand's method instead.

    Regrettably the fields inside of here are mutable collection types; this
    class doesn't mutate them however.

    This is a right-associative monoid. mempty = BuckOpts() and (<>) is
    the | operator.
    """

    argfiles: list[str] = dataclasses.field(default_factory=list)
    """
    `@file` argfiles, i.e. modefiles. buck2 expands these textually in place,
    so they come first and the explicit flags below can override them.
    """

    configs: dict[str, str] = dataclasses.field(default_factory=dict)
    """
    `-c key=value` buckconfig overrides. Merging is a dict union, so the
    right-hand side wins if keys are repeated.
    """

    modifiers: list[str] = dataclasses.field(default_factory=list)
    """`-m` modifiers. Note that uquery/utargets commands reject these."""

    target_platforms: str | None = None
    """`--target-platforms`, also rejected by the query commands."""

    extra: list[str] = dataclasses.field(default_factory=list)
    """
    Escape hatch for flags we have not modelled. Emitted at the very end of the
    generated flags.
    """

    def to_args(self) -> list[str]:
        args = [f"@{argfile}" for argfile in self.argfiles]
        for key, value in self.configs.items():
            args += ["-c", f"{key}={value}"]
        for modifier in self.modifiers:
            args += ["-m", modifier]
        if self.target_platforms is not None:
            args += ["--target-platforms", self.target_platforms]
        return args + self.extra

    def __or__(self, other: "BuckOpts") -> "BuckOpts":
        return BuckOpts(
            argfiles=self.argfiles + other.argfiles,
            configs=self.configs | other.configs,
            modifiers=self.modifiers + other.modifiers,
            target_platforms=(
                self.target_platforms
                if other.target_platforms is None
                else other.target_platforms
            ),
            extra=self.extra + other.extra,
        )


@dataclass(frozen=True)
class TestFilters:
    """
    `buck2 test`'s label-filtering flags. A monoid, like `BuckOpts`.
    """

    # Not a test class, despite the name; keeps pytest from trying to collect it.
    __test__ = False

    include: list[str] = dataclasses.field(default_factory=list)
    """`--include`: run only tests carrying one of these labels."""

    exclude: list[str] = dataclasses.field(default_factory=list)
    """`--exclude`: skip tests carrying one of these labels."""

    always_exclude: bool = False
    """
    `--always-exclude`: let `exclude` override `include` for a test matching
    both, rather than the default of `include` winning.
    """

    build_filtered: bool = False
    """`--build-filtered`: build the tests that were filtered out anyway."""

    def to_args(self) -> list[str]:
        args: list[str] = []
        for label in self.include:
            args += ["--include", label]
        for label in self.exclude:
            args += ["--exclude", label]
        if self.always_exclude:
            args.append("--always-exclude")
        if self.build_filtered:
            args.append("--build-filtered")
        return args

    def __or__(self, other: "TestFilters") -> "TestFilters":
        return TestFilters(
            include=self.include + other.include,
            exclude=self.exclude + other.exclude,
            always_exclude=self.always_exclude or other.always_exclude,
            build_filtered=self.build_filtered or other.build_filtered,
        )


@dataclass(frozen=True)
class Buck2:
    """
    A buck2 wrapper whose subcommands take structured options.

    `opts` is bound onto every command this instance runs, so e.g. a mode can
    be set once and reused:

        buck2 = ci.buck2.with_opts(BuckOpts(argfiles=["some/mode.args"]))
        buck2.build(targets)
        buck2.run(target, ["--upload"])

    This is an immutable class; with_opts gives you a new copy.
    """

    actions: AbstractCiActions

    opts: BuckOpts = dataclasses.field(default_factory=BuckOpts)
    """
    Options bound onto every command this instance runs.

    A factory rather than a shared `BuckOpts()`, since the default is reachable
    as `buck2.opts` and its collections are mutable.
    """

    def with_opts(self, opts: BuckOpts) -> typing.Self:
        """
        Returns a *new* `Buck2` with `opts` merged onto the bound options.
        """
        return dataclasses.replace(self, opts=self.opts | opts)

    def _prefix(self, subcommand: list[str], *groups: Flags) -> list[str]:
        """
        The subcommand plus its prefix flags, in order, before positionals.

        The subcommand is a list of words rather than a string because some of
        them are two words (`audit config`), and `list` rather than `Sequence`
        because a bare `str` is itself a `Sequence[str]` and would splat into
        one argument per character.
        """
        return [
            *subcommand,
            *itertools.chain.from_iterable(group.to_args() for group in groups),
        ]

    def get_config(self, opts: BuckOpts = BuckOpts()) -> dict[str, str]:
        """
        Gets the buckconfig as a map. This takes into account modefiles and
        similar added by BuckOpts.
        """

        return json.loads(
            self.actions.run_buck2(
                [*self._prefix(["audit", "config"], self.opts | opts), "--json"],
                capture_output=True,
            ).stdout
        )

    def run(
        self,
        target: str,
        args: Sequence[str] = (),
        opts: BuckOpts = BuckOpts(),
        **kwargs,
    ) -> CommandResult:
        """
        buck2 run [opts...] $target -- $args...
        """
        return self.actions.run_buck2(
            [*self._prefix(["run"], self.opts | opts), target, "--", *args], **kwargs
        )

    def build(
        self, targets: Sequence[str], opts: BuckOpts = BuckOpts(), **kwargs
    ) -> CommandResult:
        """
        buck2 build [opts...] -- $targets...

        The `--` guards targets that begin with a `-`; it is not the start of
        arguments to anything, unlike `run`'s and `test`'s.
        """
        return self.actions.run_buck2(
            [*self._prefix(["build"], self.opts | opts), "--", *targets], **kwargs
        )

    def test(
        self,
        targets: Sequence[str],
        test_args: Sequence[str] = (),
        filters: TestFilters = TestFilters(),
        opts: BuckOpts = BuckOpts(),
        **kwargs,
    ) -> CommandResult:
        """
        buck2 test [opts...] [filters...] $targets... [-- $test_args...]

        `--` is omitted entirely when there are no `test_args`, since buck2
        reads everything after it as arguments to the test binaries.
        """
        args = [*self._prefix(["test"], self.opts | opts, filters), *targets]
        if test_args:
            args += ["--", *test_args]
        return self.actions.run_buck2(args, **kwargs)

    def query(
        self,
        query_type: str,
        query: str,
        output_attributes: Sequence[str] = (),
        opts: BuckOpts = BuckOpts(),
    ) -> typing.Any:
        """
        buck2 *query [opts...] --json $query [--output-attribute attr...],
        parsed as JSON.

        `--json` is always passed so a query without output attributes still
        parses (it yields a JSON array of labels; with attributes, an object).
        An empty result maps to an empty object.
        """
        args = [*self._prefix([query_type], self.opts | opts), "--json", query]
        for attr in output_attributes:
            args += ["--output-attribute", attr]
        stdout = self.actions.run_buck2(args, capture_output=True).stdout
        if not stdout.strip():
            return {}
        return json.loads(stdout)

    # Bound positionally: as a keyword, `query_type` would still be the first
    # positional parameter, so `uquery("//...")` would fill it twice.
    uquery = functools.partialmethod(query, "uquery")
    """
    buck uquery

    N.B. this doesn't accept modifiers from BuckOpts since it's operating on
    unconfigured targets; using them will produce a runtime error.
    """

    cquery = functools.partialmethod(query, "cquery")
    """
    buck cquery
    """


@functools.cache
def is_full_mercury_repo(ci: CiActions) -> bool:
    buck2 = Buck2(ci)
    return buck2.get_config().get("mercury.is_full_mercury_repo") == "true"
