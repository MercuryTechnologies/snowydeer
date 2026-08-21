# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for managed subprocess telemetry."""

import os
import pathlib
import subprocess
import sys
from typing import Any

import pytest
from hypothesis import HealthCheck, given, settings, strategies as st
from opentelemetry.semconv._incubating.attributes import process_attributes
from opentelemetry.semconv.attributes import error_attributes
from opentelemetry.trace import SpanKind, StatusCode

from mercury_ci.actions import CommandResult, ci_actions
from mercury_ci.telemetry import semconv
from mercury_ci.testing import recording_provider


_CHILD_SCRIPT = """
import os
import sys

traceparent = os.environ["TRACEPARENT"]
assert len(traceparent) == 55
assert os.getcwd() == sys.argv[4]
sys.stdout.buffer.write(bytes.fromhex(sys.argv[1]))
sys.stderr.buffer.write(bytes.fromhex(sys.argv[2]))
raise SystemExit(int(sys.argv[3]))
"""

_PIPE_FILLING_CHILD_SCRIPT = """
import signal
import sys

signal.signal(signal.SIGTERM, signal.SIG_IGN)
sys.stderr.buffer.write(b"ready\\n")
sys.stderr.buffer.flush()
sys.stdout.buffer.write(b"x" * 1_000_000)
sys.stdout.buffer.flush()
"""


@given(
    stdout=st.binary(max_size=80),
    stderr=st.binary(max_size=80),
    returncode=st.integers(min_value=0, max_value=8),
    check=st.booleans(),
    explicit_cwd=st.booleans(),
)
@settings(
    max_examples=20,
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
def test_managed_process_integration(
    stdout: bytes,
    stderr: bytes,
    returncode: int,
    check: bool,
    explicit_cwd: bool,
    tmp_path: pathlib.Path,
) -> None:
    provider, exporter = recording_provider()
    assert pathlib.Path(sys.executable).is_absolute()
    cwd = tmp_path if explicit_cwd else None
    expected_working_directory = str(tmp_path) if explicit_cwd else os.getcwd()
    args = [
        sys.executable,
        "-c",
        _CHILD_SCRIPT,
        stdout.hex(),
        stderr.hex(),
        str(returncode),
        expected_working_directory,
    ]

    result: CommandResult | None = None
    error: subprocess.CalledProcessError | None = None
    with ci_actions(exit_on_child_failure=False, tracer_provider=provider) as actions:
        try:
            result = actions.run_subprocess(
                args,
                capture_output=True,
                capture_err=True,
                check=check,
                cwd=cwd,
            )
        except subprocess.CalledProcessError as caught:
            error = caught

    if check and returncode != 0:
        assert error is not None
        assert error.returncode == returncode
        assert error.stdout == stdout
        assert error.stderr == stderr
    else:
        assert error is None
        assert result == CommandResult(returncode, args, stdout, stderr)

    finished_spans = exporter.get_finished_spans()
    spans = [span for span in finished_spans if span.kind is SpanKind.CLIENT]
    assert len(spans) == 1
    span = spans[0]
    assert span.name == pathlib.Path(sys.executable).name
    assert span.kind is SpanKind.CLIENT
    assert span.attributes is not None
    assert span.attributes[process_attributes.PROCESS_COMMAND_ARGS] == (
        pathlib.Path(sys.executable).name,
        *args[1:],
    )
    assert (
        span.attributes[process_attributes.PROCESS_EXECUTABLE_NAME]
        == pathlib.Path(sys.executable).name
    )
    assert span.attributes[process_attributes.PROCESS_EXECUTABLE_PATH] == sys.executable
    assert (
        span.attributes[process_attributes.PROCESS_WORKING_DIRECTORY]
        == expected_working_directory
    )
    assert isinstance(span.attributes[process_attributes.PROCESS_PID], int)
    assert span.attributes[process_attributes.PROCESS_EXIT_CODE] == returncode
    unexpected_failure = check and returncode != 0
    assert span.status.status_code is (
        StatusCode.ERROR if unexpected_failure else StatusCode.UNSET
    )
    if not unexpected_failure:
        assert error_attributes.ERROR_TYPE not in span.attributes
    else:
        assert (
            span.attributes[error_attributes.ERROR_TYPE]
            == "subprocess.CalledProcessError"
        )

    root = next(span for span in finished_spans if span.kind is SpanKind.INTERNAL)
    assert root.attributes is not None
    assert root.attributes[semconv.CI_RUN_CHILD_COUNT] == 1
    assert root.attributes[semconv.CI_RUN_FAILED_CHILD_COUNT] == int(unexpected_failure)

    provider.shutdown()


def test_interrupted_managed_process_is_terminated_and_drained(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    provider, exporter = recording_provider()
    original_communicate = subprocess.Popen.communicate
    interrupted_processes: list[subprocess.Popen[bytes]] = []

    def interrupt_first_communicate(
        process: subprocess.Popen[bytes], *args: Any, **kwargs: Any
    ) -> tuple[bytes | None, bytes | None]:
        if not interrupted_processes:
            interrupted_processes.append(process)
            assert process.stderr is not None
            assert process.stderr.readline() == b"ready\n"
            raise KeyboardInterrupt
        return original_communicate(process, *args, **kwargs)

    monkeypatch.setattr(subprocess.Popen, "communicate", interrupt_first_communicate)

    with pytest.raises(KeyboardInterrupt):
        with ci_actions(tracer_provider=provider) as actions:
            actions.run_subprocess(
                [sys.executable, "-c", _PIPE_FILLING_CHILD_SCRIPT],
                capture_output=True,
                capture_err=True,
            )

    assert len(interrupted_processes) == 1
    process = interrupted_processes[0]
    assert process.returncode is not None
    assert process.stdout is not None and process.stdout.closed
    assert process.stderr is not None and process.stderr.closed

    client_span = next(
        span for span in exporter.get_finished_spans() if span.kind is SpanKind.CLIENT
    )
    assert client_span.status.status_code is StatusCode.ERROR
    assert client_span.attributes is not None
    assert (
        client_span.attributes[error_attributes.ERROR_TYPE]
        == "builtins.KeyboardInterrupt"
    )
    provider.shutdown()
