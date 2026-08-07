# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for `mercury_ci.testing.RecordingCiActions`."""

import subprocess

import pytest

from mercury_ci.actions import CommandResult
from mercury_ci.testing import RecordingCiActions


def test_records_calls_and_defaults_to_empty_success() -> None:
    actions = RecordingCiActions()
    result = actions.run_buck2(["build", "//a"])
    assert actions.buck2_calls == [["build", "//a"]]
    assert result.returncode == 0
    assert result.stdout == b""


@pytest.mark.parametrize(
    ("returned", "expected_stdout"),
    [("text", b"text"), (b"raw", b"raw")],
)
def test_handler_stdout_shortcuts(returned: object, expected_stdout: bytes) -> None:
    actions = RecordingCiActions(buck2_handler=lambda _: returned)
    assert actions.run_buck2([]).stdout == expected_stdout


def test_handler_may_return_command_result() -> None:
    canned = CommandResult(0, ["x"], b"o", b"e")
    actions = RecordingCiActions(buck2_handler=lambda _: canned)
    assert actions.run_buck2([]) is canned


def test_nonzero_result_raises_under_check() -> None:
    failure = CommandResult(2, ["boom"], b"", b"")
    actions = RecordingCiActions(buck2_handler=lambda _: failure)
    with pytest.raises(subprocess.CalledProcessError):
        actions.run_buck2(["x"])


def test_nonzero_result_returned_when_check_false() -> None:
    failure = CommandResult(2, ["boom"], b"out", b"")
    actions = RecordingCiActions(subprocess_handler=lambda _: failure)
    result = actions.run_subprocess(["x"], check=False)
    assert result.returncode == 2
    assert result.stdout == b"out"


def test_subprocess_recording() -> None:
    actions = RecordingCiActions(subprocess_handler=lambda _: "hi")
    assert actions.run_subprocess(["git", "rev-parse"]).stdout == b"hi"
    assert actions.subprocess_calls == [["git", "rev-parse"]]


def test_side_effect_recording() -> None:
    actions = RecordingCiActions()
    actions.log("msg")
    actions.write_file("path", "content")
    actions.touch_file("touched")
    assert actions.logs == ["msg"]
    assert actions.written == [("path", "content")]
    assert actions.touched == ["touched"]


def test_read_json_file() -> None:
    actions = RecordingCiActions(json_files={"a.json": {"k": 1}})
    assert actions.read_json_file("a.json") == {"k": 1}
    with pytest.raises(KeyError):
        actions.read_json_file("missing.json")
