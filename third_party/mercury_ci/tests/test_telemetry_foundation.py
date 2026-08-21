# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for tracer configuration and trace-context propagation."""

import os
from collections.abc import Mapping
from unittest.mock import patch

import expecttest
import pytest
from hypothesis import given, strategies as st
from opentelemetry.sdk.resources import SERVICE_NAME
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.trace import (
    INVALID_SPAN_CONTEXT,
    NonRecordingSpan,
    SpanContext,
    TraceFlags,
    TraceState,
    get_current_span,
)

import mercury_ci.telemetry.tracer_provider as tracer_provider
from mercury_ci.env import parse_bool
from mercury_ci.telemetry import _Telemetry
from mercury_ci.telemetry.tracer_provider import build_tracer, should_export
from mercury_ci.telemetry.tracer_provider import TracerSetup
from mercury_ci.telemetry.tracecontext import child_env, parent_context_from_env


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (None, False),
        ("", False),
        ("false", False),
        ("0", False),
        ("true", True),
        (" YES ", True),
        ("On", True),
        ("1", True),
    ],
)
def test_parse_bool(value: str | None, expected: bool) -> None:
    assert parse_bool(value) is expected


@st.composite
def span_contexts(draw: st.DrawFn) -> SpanContext:
    return SpanContext(
        trace_id=draw(st.integers(min_value=1, max_value=2**128 - 1)),
        span_id=draw(st.integers(min_value=1, max_value=2**64 - 1)),
        is_remote=False,
        trace_flags=TraceFlags(draw(st.integers(min_value=0, max_value=255))),
        trace_state=TraceState(),
    )


@given(
    context=span_contexts(),
    unrelated=st.dictionaries(
        st.text(
            alphabet=st.characters(
                blacklist_categories=("Cs",), blacklist_characters="="
            ),
            min_size=1,
            max_size=20,
        ).filter(lambda key: key.lower() not in {"traceparent", "tracestate"}),
        st.text(max_size=30),
        max_size=10,
    ),
)
def test_trace_context_round_trips_without_changing_unrelated_environment(
    context: SpanContext, unrelated: dict[str, str]
) -> None:
    propagated = child_env(NonRecordingSpan(context), unrelated)

    assert all(propagated[key] == value for key, value in unrelated.items())
    extracted = get_current_span(parent_context_from_env(propagated)).get_span_context()
    assert extracted.trace_id == context.trace_id
    assert extracted.span_id == context.span_id
    assert extracted.trace_flags == context.trace_flags
    assert extracted.is_remote


@given(
    env=st.dictionaries(st.text(min_size=1), st.text(), max_size=10),
)
def test_invalid_span_never_adds_context_or_leaks_lowercase_carriers(
    env: dict[str, str],
) -> None:
    result = child_env(NonRecordingSpan(INVALID_SPAN_CONTEXT), env)

    assert "traceparent" not in result
    assert "tracestate" not in result
    assert result.get("TRACEPARENT") == env.get("TRACEPARENT")
    assert result.get("TRACESTATE") == env.get("TRACESTATE")


def test_export_requires_enabled_supported_otlp_endpoint() -> None:
    base: Mapping[str, str] = {"OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel"}
    assert should_export(base)
    assert not should_export(base | {"OTEL_SDK_DISABLED": "true"})
    assert not should_export(base | {"OTEL_TRACES_EXPORTER": "none"})
    assert not should_export({})


def test_injected_provider_is_used_but_remains_caller_owned() -> None:
    provider = TracerProvider(shutdown_on_exit=False)
    setup = build_tracer(env={}, tracer_provider=provider)

    assert setup.provider is provider
    assert setup.tracer is provider.get_tracer("mercury_ci")
    assert not setup.owns_provider


def test_exporting_provider_uses_fixed_service_name() -> None:
    with patch.dict(
        os.environ,
        {
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318",
            "OTEL_RESOURCE_ATTRIBUTES": "service.name=also-wrong,custom=kept",
            "OTEL_SERVICE_NAME": "wrong",
        },
        clear=True,
    ):
        setup = build_tracer(env=os.environ)

    assert isinstance(setup.provider, TracerProvider)
    assert setup.provider.resource.attributes[SERVICE_NAME] == "mercury_ci"
    assert setup.provider.resource.attributes["custom"] == "kept"
    setup.provider.shutdown()


def test_exporter_configuration_failure_is_logged(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    def fail_to_build(*_args: object) -> None:
        raise RuntimeError("exporter exploded")

    monkeypatch.setattr(tracer_provider, "_build_exporting_provider", fail_to_build)
    setup = build_tracer(env={"OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318"})

    assert setup.provider is None
    expecttest.assert_expected_inline(
        capsys.readouterr().err,
        """\
mercury_ci: warning: Mercury CI could not configure OpenTelemetry; tracing is disabled for this job (RuntimeError: exporter exploded)
""",
    )


class _FailingShutdownProvider(TracerProvider):
    def force_flush(self, timeout_millis: int = 30_000) -> bool:
        raise RuntimeError(f"flush exploded after {timeout_millis}ms")

    def shutdown(self) -> None:
        raise ValueError("shutdown exploded")


def test_exporter_shutdown_failures_are_logged(
    capsys: pytest.CaptureFixture[str],
) -> None:
    provider = _FailingShutdownProvider(shutdown_on_exit=False)
    telemetry = _Telemetry(env={}, root_span_name="test", tracer_provider=provider)
    telemetry._setup = TracerSetup(
        tracer=telemetry._setup.tracer,
        provider=provider,
        owns_provider=True,
    )

    telemetry.shutdown()

    expecttest.assert_expected_inline(
        capsys.readouterr().err,
        """\
mercury_ci: warning: OpenTelemetry force flush failed (RuntimeError: flush exploded after 5000ms)
mercury_ci: warning: OpenTelemetry shutdown failed (ValueError: shutdown exploded)
""",
    )


def test_grpc_configuration_is_rejected() -> None:
    with pytest.raises(ValueError) as raised:
        build_tracer(
            env={
                "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
                "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
            }
        )
    expecttest.assert_expected_inline(
        str(raised.value),
        """\
Mercury CI only supports OTLP protocol 'http/protobuf'; got 'grpc'""",
    )
