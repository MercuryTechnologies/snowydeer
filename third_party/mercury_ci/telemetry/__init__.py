# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Managed subprocess tracing for Mercury CI."""

import os
import pathlib
import shutil
import subprocess
import threading
import time
from collections.abc import Iterator, Mapping
from contextlib import contextmanager, suppress
from typing import Any

from opentelemetry.semconv._incubating.attributes import (
    cicd_attributes,
    process_attributes,
)
from opentelemetry.semconv.attributes import error_attributes
from opentelemetry.trace import (
    Span,
    SpanKind,
    Status,
    StatusCode,
    TracerProvider,
)

from mercury_ci.env import parse_bool

from . import semconv
from .tracecontext import child_env, parent_context_from_env
from .tracer_provider import (
    TracerSetup,
    _warn,
    _warn_exception,
    build_tracer,
)


_FLUSH_TIMEOUT_MILLIS = 5_000
_SLOW_SHUTDOWN_SECONDS = 2


class _Telemetry:
    def __init__(
        self,
        *,
        env: Mapping[str, str],
        root_span_name: str,
        tracer_provider: TracerProvider | None = None,
    ) -> None:
        self._setup: TracerSetup = build_tracer(
            env=env, tracer_provider=tracer_provider
        )
        self._parent_context = parent_context_from_env(env)
        self._root_span_name = root_span_name
        self._required_check = parse_bool(env.get("CI_REQUIRED_CHECK"))
        self._root_span: Span | None = None
        self._counter_lock = threading.Lock()
        self._child_count = 0
        self._failed_child_count = 0

    @property
    def child_count(self) -> int:
        with self._counter_lock:
            return self._child_count

    @property
    def failed_child_count(self) -> int:
        with self._counter_lock:
            return self._failed_child_count

    @property
    def has_provider(self) -> bool:
        return self._setup.provider is not None

    def _record_child(self, *, failed: bool) -> None:
        with self._counter_lock:
            self._child_count += 1
            if failed:
                self._failed_child_count += 1

    def process_env(self, span: Span) -> dict[str, str]:
        return child_env(span, os.environ)

    @contextmanager
    def activate_root_span(self) -> Iterator[None]:
        with self._setup.tracer.start_as_current_span(
            self._root_span_name,
            context=self._parent_context,
            kind=SpanKind.INTERNAL,
            attributes={
                cicd_attributes.CICD_PIPELINE_TASK_NAME: self._root_span_name,
                semconv.CI_REQUIRED_CHECK: self._required_check,
                semconv.DEPRECATED_CI_REQUIRED_CHECK: self._required_check,
            },
            record_exception=False,
            set_status_on_exception=False,
        ) as root_span:
            self._root_span = root_span
            try:
                yield
            finally:
                self._root_span = None

    def set_root_span_result(
        self,
        *,
        attributes: Mapping[str, Any],
        exit_code: int,
        error: BaseException | None,
    ) -> None:
        if self._root_span is None:
            raise RuntimeError("the Mercury CI root span is not active")

        failed = exit_code != 0
        for name, value in attributes.items():
            self._root_span.set_attribute(name, value)
        result = (
            cicd_attributes.CicdPipelineTaskRunResultValues.FAILURE.value
            if failed
            else cicd_attributes.CicdPipelineTaskRunResultValues.SUCCESS.value
        )
        lifecycle_attributes = {
            cicd_attributes.CICD_PIPELINE_TASK_RUN_RESULT: result,
            semconv.CI_RUN_CHILD_COUNT: self.child_count,
            semconv.CI_RUN_EXIT_CODE: exit_code,
            semconv.CI_RUN_FAILED_CHILD_COUNT: self.failed_child_count,
        }
        for name, value in lifecycle_attributes.items():
            self._root_span.set_attribute(name, value)
        if failed:
            if error is not None:
                error_type = f"{type(error).__module__}.{type(error).__qualname__}"
                self._root_span.set_attribute(error_attributes.ERROR_TYPE, error_type)
            self._root_span.set_status(Status(StatusCode.ERROR))
            if error is not None:
                self._root_span.record_exception(error)

    def shutdown(self) -> None:
        if self._setup.owns_provider and self._setup.provider is not None:
            # Export failure must not change the result of an otherwise-finished job.
            started = time.monotonic()
            try:
                flushed = self._setup.provider.force_flush(
                    timeout_millis=_FLUSH_TIMEOUT_MILLIS
                )
                if not flushed:
                    timeout_seconds = _FLUSH_TIMEOUT_MILLIS / 1_000
                    _warn(
                        "OpenTelemetry force flush did not complete within "
                        f"{timeout_seconds:g}s"
                    )
            except Exception as error:
                _warn_exception("OpenTelemetry force flush failed", error)
            try:
                self._setup.provider.shutdown()
            except Exception as error:
                _warn_exception("OpenTelemetry shutdown failed", error)
            finally:
                elapsed = time.monotonic() - started
                if elapsed > _SLOW_SHUTDOWN_SECONDS:
                    _warn(f"OpenTelemetry shutdown took {elapsed:.1f}s")


def _start_process_child_span(
    telemetry: _Telemetry,
    args: list[str],
    *,
    cwd: os.PathLike[str] | str | None,
) -> Span:
    """Start a span describing a managed child process."""
    requested_executable = pathlib.Path(args[0])
    executable_name = requested_executable.name
    command_args = list(args)
    if requested_executable.is_absolute():
        # Keep Nix store paths out of command args; the full path is recorded below.
        command_args[0] = executable_name
    span = telemetry._setup.tracer.start_span(
        executable_name,
        kind=SpanKind.CLIENT,
    )
    span.set_attribute(process_attributes.PROCESS_EXECUTABLE_NAME, executable_name)
    span.set_attribute(process_attributes.PROCESS_COMMAND_ARGS, command_args)
    span.set_attribute(
        process_attributes.PROCESS_WORKING_DIRECTORY,
        os.getcwd() if cwd is None else os.path.abspath(cwd),
    )
    span.set_attribute(semconv.CI_REQUIRED_CHECK, telemetry._required_check)
    span.set_attribute(semconv.DEPRECATED_CI_REQUIRED_CHECK, telemetry._required_check)
    executable_path = (
        str(requested_executable)
        if requested_executable.is_absolute()
        else shutil.which(args[0])
    )
    if executable_path is not None:
        span.set_attribute(
            process_attributes.PROCESS_EXECUTABLE_PATH,
            os.path.abspath(executable_path),
        )
    return span


def _end_process_child_span(
    span: Span,
    *,
    check: bool,
    returncode: int | None = None,
    error: BaseException | None = None,
) -> bool:
    """Record a process result, end its span, and return whether it failed.

    Nonzero exit codes are failures only when ``check`` is true. This
    intentionally follows ``subprocess`` check semantics rather than the
    OpenTelemetry CLI convention because callers use ``check=False`` when a
    nonzero exit is an expected result.
    """
    failed = error is not None or (check and returncode is not None and returncode != 0)
    if returncode is not None:
        span.set_attribute(process_attributes.PROCESS_EXIT_CODE, returncode)
    if failed:
        error_type = (
            "subprocess.CalledProcessError"
            if error is None
            else f"{type(error).__module__}.{type(error).__qualname__}"
        )
        span.set_attribute(error_attributes.ERROR_TYPE, error_type)
        span.set_status(Status(StatusCode.ERROR))
    if error is not None:
        span.record_exception(error)
    span.end()
    return failed


def _terminate_and_reap(process: subprocess.Popen[bytes]) -> None:
    """Stop a child whose synchronous wait was interrupted.

    `Popen.__exit__` only waits, which can hang forever when `communicate` was
    interrupted while the child is still running. Terminating and then reaping
    here keeps the process lifetime inside `run_subprocess` and lets its span
    end deterministically.
    """
    if process.poll() is None:
        with suppress(ProcessLookupError):
            process.terminate()
    try:
        process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        with suppress(ProcessLookupError):
            process.kill()
        process.communicate()


def _run_subprocess(
    telemetry: _Telemetry,
    args: list[str],
    *,
    capture_output: bool,
    capture_err: bool,
    check: bool,
    cwd: os.PathLike[str] | str | None,
) -> subprocess.CompletedProcess[bytes]:
    """Run one child to completion while owning its span and process lifetime."""
    span = _start_process_child_span(telemetry, args, cwd=cwd)
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            args,
            cwd=cwd,
            env=telemetry.process_env(span),
            stdout=subprocess.PIPE if capture_output else None,
            stderr=subprocess.PIPE if capture_err else None,
        )
        span.set_attribute(process_attributes.PROCESS_PID, process.pid)
        stdout, stderr = process.communicate()
        telemetry._record_child(
            failed=_end_process_child_span(
                span, check=check, returncode=process.returncode
            )
        )
        return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    except (Exception, KeyboardInterrupt, SystemExit) as error:
        # Interrupts still need to end the child process before they escape.
        if process is not None:
            _terminate_and_reap(process)
        telemetry._record_child(
            failed=_end_process_child_span(
                span,
                check=check,
                returncode=None if process is None else process.returncode,
                error=error,
            )
        )
        raise
