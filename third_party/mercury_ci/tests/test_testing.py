# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for `mercury_ci.testing.RecordingCiActions`."""

import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

import expecttest
import pytest
from hypothesis import given, strategies as st

from mercury_ci.actions import CommandResult, ci_actions
from mercury_ci.testing import (
    Buck2Invocation,
    CommandInvocation,
    RecordingCiActions,
)
from mercury_ci.testing.strip_ansi import eat_terminal_codes


def test_records_calls_and_defaults_to_empty_success() -> None:
    actions = RecordingCiActions()
    result = actions.run_buck2(["build", "//a"])
    assert actions.buck2_invocation_args == [["build", "//a"]]
    assert result.returncode == 0
    assert result.stdout == b""


@pytest.mark.parametrize(
    "invocation",
    [CommandInvocation(["git", "status"], None), Buck2Invocation(["build"], None)],
)
def test_recorded_invocations_are_explicitly_unhashable(invocation: object) -> None:
    with pytest.raises(TypeError):
        hash(invocation)


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
    assert actions.subprocess_invocation_args == [["git", "rev-parse"]]


def test_records_working_directories() -> None:
    actions = RecordingCiActions()
    actions.run_subprocess(["git", "status"], cwd="/base")
    actions.run_buck2(["targets", "//..."], cwd="/head")
    assert [inv.cwd for inv in actions.subprocess_invocations] == ["/base"]
    assert [inv.cwd for inv in actions.buck2_invocations] == ["/head"]


def test_side_effect_recording() -> None:
    actions = RecordingCiActions()
    actions.log("msg")
    actions.write_file("path", "content")
    actions.touch_file("touched")
    assert actions.logs == ["msg"]
    assert actions.written == [("path", "content")]
    assert actions.touched == ["touched"]


@pytest.mark.parametrize(
    "value",
    [Path("not-json"), b"bytes", ["mixed", 1]],
)
def test_root_span_attributes_are_validated_when_set(value: object) -> None:
    actions = RecordingCiActions()
    with pytest.raises(TypeError, match="root span attribute 'invalid'"):
        actions.set_root_span_attr("invalid", value)  # type: ignore[arg-type]
    assert actions.root_span_attrs == {}


@given(
    text=st.text(
        alphabet=st.characters(blacklist_categories=("Cc",)),
        max_size=100,
    )
)
def test_eat_terminal_codes_preserves_arbitrary_text(text: str) -> None:
    decorated = (
        "\x1b[7m"
        "\x1b]0;window title\a"
        "\x1bPignored device control string\x1b\\"
        f"{text}"
        "\x1b]8;;https://example.com\x1b\\"
        "\x1b]8;;\x1b\\"
        "\x1b[0m"
    )

    assert eat_terminal_codes(decorated) == text


def test_eat_terminal_codes_handles_c1_and_incomplete_sequences() -> None:
    assert eat_terminal_codes("a\x9b31mb\x9dtitle\x9cc\x1b[123") == "abc"


def test_ci_actions_emits_root_attributes_without_a_tracer_provider(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with (
        patch.dict(os.environ, {"OTEL_SDK_DISABLED": "true"}, clear=True),
        patch.object(sys, "argv", ["direct-job.py"]),
        pytest.raises(RuntimeError, match="boom"),
    ):
        with ci_actions() as actions:
            actions.set_root_span_attrs(
                {
                    "thing.count": 3,
                    "thing.name": "example",
                    "thing.ok": True,
                    "thing.tags": ["one", "two"],
                }
            )
            raise RuntimeError("boom")

    expecttest.assert_expected_inline(
        eat_terminal_codes(capsys.readouterr().err),
        """\
• {"root_span_attributes": {"thing.count": 3, "thing.name": "example", "thing.ok": true, "thing.tags": ["one", "two"]}}
""",
    )


def test_ci_actions_exits_on_child_failure_by_default(
    capsys: pytest.CaptureFixture[str],
) -> None:
    failure = subprocess.CalledProcessError(
        17, ["failing-command"], output=b"captured out", stderr=b"captured err"
    )
    with pytest.raises(SystemExit) as exited:
        with ci_actions():
            raise failure
    assert exited.value.code == 17
    expecttest.assert_expected_inline(
        eat_terminal_codes(capsys.readouterr().err),
        """\
Command '['failing-command']' returned non-zero exit status 17.
stdout:
captured out
stderr:
captured err
• {"root_span_attributes": {}}
""",
    )


def test_ci_actions_can_propagate_child_failure() -> None:
    failure = subprocess.CalledProcessError(17, ["failing-command"])
    with pytest.raises(subprocess.CalledProcessError) as raised:
        with ci_actions(exit_on_child_failure=False):
            raise failure
    assert raised.value is failure


def test_github_step_summary_is_visible_in_local_logs(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    with ci_actions() as actions:
        actions.write_github_step_summary("## Summary\n\nEverything worked.")
    assert (
        "GITHUB_STEP_SUMMARY:\n## Summary\n\nEverything worked."
        in capsys.readouterr().err
    )


def test_github_step_summary_appends_to_github_file(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    output = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(output))
    with ci_actions() as actions:
        actions.write_github_step_summary("first")
        actions.write_github_step_summary("second\n")
    assert output.read_text(encoding="utf-8") == "first\nsecond\n"


def test_recording_actions_capture_github_step_summaries() -> None:
    actions = RecordingCiActions()
    actions.write_github_step_summary("## Summary")
    assert actions.github_step_summaries == ["## Summary\n"]


def test_read_json_file() -> None:
    actions = RecordingCiActions(json_files={"a.json": {"k": 1}})
    assert actions.read_json_file("a.json") == {"k": 1}
    with pytest.raises(KeyError):
        actions.read_json_file("missing.json")
