# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Test helper: a non-executing `AbstractCiActions` that records calls."""

from collections.abc import Callable, Mapping

from mercury_ci.actions import AbstractCiActions, CommandResult, StrOrPath

# Given a recorded command's args, returns a `CommandResult`, a `str`/`bytes`
# (used as success stdout), or None for an empty success.
Handler = Callable[[list[str]], "CommandResult | str | bytes | None"]


def _as_command_result(
    value: "CommandResult | str | bytes | None", args: list[str]
) -> CommandResult:
    if value is None:
        return CommandResult(0, args, b"", b"")
    if isinstance(value, CommandResult):
        return value
    if isinstance(value, (bytes, bytearray)):
        return CommandResult(0, args, bytes(value), b"")
    if isinstance(value, str):
        return CommandResult(0, args, value.encode(), b"")
    raise TypeError(f"handler returned unsupported value {value!r}")


def _finish(result: CommandResult, check: bool) -> CommandResult:
    # Mirror production: a nonzero result raises under check=True, else returns.
    return result.ok() if check else result


class RecordingCiActions(AbstractCiActions):
    """Records calls into `buck2_calls`/`subprocess_calls`/`written`/`touched`/
    `logs`; `read_json_file` serves from `json_files`."""

    def __init__(
        self,
        *,
        buck2_handler: Handler | None = None,
        subprocess_handler: Handler | None = None,
        json_files: Mapping[str, object] | None = None,
    ):
        self.buck2_calls: list[list[str]] = []
        self.subprocess_calls: list[list[str]] = []
        self.written: list[tuple[str, str]] = []
        self.touched: list[str] = []
        self.logs: list[str] = []
        self.json_files: dict[str, object] = dict(json_files or {})
        self._buck2_handler = buck2_handler
        self._subprocess_handler = subprocess_handler

    def log(self, message: str) -> None:
        self.logs.append(message)

    def run_subprocess(
        self,
        args: list[str],
        capture_output: bool = False,
        capture_err: bool = False,
        check: bool = True,
    ) -> CommandResult:
        recorded = list(args)
        self.subprocess_calls.append(recorded)
        value = self._subprocess_handler(recorded) if self._subprocess_handler else None
        return _finish(_as_command_result(value, recorded), check)

    def run_buck2(
        self,
        args: list[str],
        capture_output: bool = False,
        capture_err: bool = False,
        check: bool = True,
        log_critical_path: bool = False,
    ) -> CommandResult:
        recorded = list(args)
        self.buck2_calls.append(recorded)
        value = self._buck2_handler(recorded) if self._buck2_handler else None
        return _finish(_as_command_result(value, recorded), check)

    def touch_file(self, path: StrOrPath) -> None:
        self.touched.append(str(path))

    def write_file(
        self, path: StrOrPath, content: str, print_content: bool = False
    ) -> None:
        self.written.append((str(path), content))

    def read_json_file(self, path: StrOrPath) -> object:
        return self.json_files[str(path)]
