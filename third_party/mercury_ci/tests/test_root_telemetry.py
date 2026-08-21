# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for Mercury CI root-span telemetry."""

import os
import sys
from unittest.mock import patch

import expecttest
import pytest
from hypothesis import given, settings, strategies as st
from opentelemetry.semconv._incubating.attributes import cicd_attributes
from opentelemetry.trace import StatusCode

from mercury_ci.actions import ci_actions
from mercury_ci.telemetry import semconv
from mercury_ci.testing import recording_provider


def test_ci_task_span_tree_golden(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MERCURY_CI_TARGET", "//example:job")
    monkeypatch.setenv("CI_REQUIRED_CHECK", "true")
    monkeypatch.delenv("TRACEPARENT", raising=False)
    monkeypatch.delenv("TRACESTATE", raising=False)
    provider, exporter = recording_provider()

    with ci_actions(tracer_provider=provider) as actions:
        actions.set_root_span_attrs({"job.attempt": 2, "job.labels": ("one", "two")})
        actions.run_subprocess([sys.executable, "-c", "pass"])
        with provider.get_tracer("test").start_as_current_span("library work"):
            actions.run_subprocess(
                [sys.executable, "-c", "raise SystemExit(7)"], check=False
            )

    exporter.assert_finished_spans(
        expecttest.Expect(
            """\
//example:job [INTERNAL/UNSET] parent=<none>
  ci_required_check = true
  cicd.pipeline.task.name = "//example:job"
  cicd.pipeline.task.run.result = "success"
  job.attempt = 2
  job.labels = ["one", "two"]
  mercury.ci.is_required_check = true
  mercury.ci.run.child_span_count = 2
  mercury.ci.run.exit_code = 0
  mercury.ci.run.failed_child_span_count = 0
library work [INTERNAL/UNSET] parent=<root>
python#1 [CLIENT/UNSET] parent=<root>
  ci_required_check = true
  mercury.ci.is_required_check = true
  process.command_args = ["python", "-c", "pass"]
  process.executable.name = "python"
  process.executable.path = "<absolute>/python"
  process.exit.code = 0
  process.pid = "<pid>"
  process.working_directory = "<absolute>"
python#2 [CLIENT/UNSET] parent=library work
  ci_required_check = true
  mercury.ci.is_required_check = true
  process.command_args = ["python", "-c", "raise SystemExit(7)"]
  process.executable.name = "python"
  process.executable.path = "<absolute>/python"
  process.exit.code = 7
  process.pid = "<pid>"
  process.working_directory = "<absolute>"
"""
        )
    )
    provider.shutdown()


def test_span_tree_distinguishes_same_named_parents() -> None:
    provider, exporter = recording_provider()
    tracer = provider.get_tracer("test")

    with tracer.start_as_current_span("same"):
        with tracer.start_as_current_span("same"):
            with tracer.start_as_current_span("leaf"):
                pass

    exporter.assert_finished_spans(
        expecttest.Expect(
            """\
same#1 [INTERNAL/UNSET] parent=<none>
leaf [INTERNAL/UNSET] parent=same#2
same#2 [INTERNAL/UNSET] parent=<root>
"""
        )
    )
    provider.shutdown()


@given(
    code=st.one_of(
        st.none(),
        st.integers(min_value=-5, max_value=5),
        st.text(min_size=1, max_size=20),
    )
)
@settings(max_examples=20)
def test_direct_invocation_system_exit_is_reflected_on_root_span(
    code: int | str | None,
) -> None:
    provider, exporter = recording_provider()

    with patch.dict(os.environ), patch.object(sys, "argv", ["/tmp/direct-job.py"]):
        os.environ.pop("MERCURY_CI_TARGET", None)
        os.environ.pop("TRACEPARENT", None)
        with pytest.raises(SystemExit) as raised:
            with ci_actions(tracer_provider=provider):
                raise SystemExit(code)
    assert raised.value.code == code

    root = exporter.get_finished_spans()[0]
    attributes = root.attributes or {}
    normalized_code = code if isinstance(code, int) else 0 if code is None else 1
    assert root.name == "direct-job.py"
    assert attributes[semconv.CI_RUN_EXIT_CODE] == normalized_code
    assert attributes[cicd_attributes.CICD_PIPELINE_TASK_RUN_RESULT] == (
        cicd_attributes.CicdPipelineTaskRunResultValues.SUCCESS.value
        if normalized_code == 0
        else cicd_attributes.CicdPipelineTaskRunResultValues.FAILURE.value
    )
    assert root.status.status_code is (
        StatusCode.UNSET if normalized_code == 0 else StatusCode.ERROR
    )
    provider.shutdown()


def test_keyboard_interrupt_uses_shell_exit_code() -> None:
    provider, exporter = recording_provider()

    with pytest.raises(KeyboardInterrupt):
        with ci_actions(tracer_provider=provider):
            raise KeyboardInterrupt

    root = exporter.get_finished_spans()[0]
    attributes = root.attributes or {}
    assert attributes[semconv.CI_RUN_EXIT_CODE] == 130
    assert root.status.status_code is StatusCode.ERROR
    provider.shutdown()
