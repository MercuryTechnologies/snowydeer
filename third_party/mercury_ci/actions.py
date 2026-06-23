# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

import subprocess
import sys
import json
from dataclasses import dataclass
import os
import shlex
import functools
import typing


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


class CiActions(AbstractCiActions):
    def log(self, message: str):
        print(f"{ANSI_CYAN}• {message}{ANSI_RESET}", file=sys.stderr)

    def run_subprocess(
        self, args: list[str], capture_output=False, capture_err=False, check=True
    ) -> CommandResult:
        kwargs: dict = {"check": check}
        if capture_output:
            kwargs["stdout"] = subprocess.PIPE
        if capture_err:
            kwargs["stderr"] = subprocess.PIPE

        if len(args) < 50:
            self.log(f"$ {shlex.join(args)}")
        else:
            self.log(f"$ {shlex.join(args[:50])} ...")
        otel_attrs_args = []
        # Add an attribute if this is happening as part of a required check.
        # This allows us to vary our SLO across required/optional checks.
        if os.environ.get("CI_REQUIRED_CHECK", None):
            otel_attrs_args.append("--attribute")
            otel_attrs_args.append("ci_required_check=true")

        hotel_args = []
        hotel = os.environ.get("HOTEL")
        if not hotel:
            raise ValueError(
                'Please set HOTEL to the hotel executable or if you really want to skip telemetry, set it to "skip"'
            )
        elif hotel != "skip":
            hotel_args = [hotel, "exec"] + otel_attrs_args
        completed_process = CommandResult.from_subprocess(
            subprocess.run(hotel_args + args, **kwargs)
        )
        return completed_process

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


@dataclass
class Buck2:
    actions: CiActions

    def get_config(self) -> dict[str, str]:
        """
        Gets the buckconfig as a map.
        """

        return json.loads(
            self.actions.run_buck2(
                ["audit", "config", "--json"], capture_output=True
            ).stdout
        )

    def run(self, target: str, args: list[str] = [], **kwargs) -> CommandResult:
        """
        buck2 run $target $args...
        """
        return self.actions.run_buck2(["run", target, "--", *args], **kwargs)

    def build(self, targets: list[str], **kwargs) -> CommandResult:
        """
        buck2 build $targets...
        """
        return self.actions.run_buck2(["build", "--", *targets], **kwargs)

    def test(self, targets: list[str], **kwargs) -> CommandResult:
        """
        buck2 test $targets...
        """
        return self.actions.run_buck2(["test", *targets], **kwargs)


@functools.cache
def is_full_mercury_repo(ci: CiActions) -> bool:
    buck2 = Buck2(ci)
    return buck2.get_config().get("mercury.is_full_mercury_repo") == "true"
