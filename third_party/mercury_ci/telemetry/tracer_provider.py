# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tracer-provider construction for Mercury CI telemetry."""

import sys
from collections.abc import Mapping
from dataclasses import dataclass

from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider as SdkTracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import NoOpTracerProvider, Tracer, TracerProvider
from opentelemetry.util.re import parse_env_headers

from mercury_ci.env import parse_bool


_SERVICE_NAME = "mercury_ci"
_EXPORT_TIMEOUT_SECONDS = 5


def _try_build_exporting_provider(
    config: "_OtlpHttpConfig",
) -> SdkTracerProvider | None:
    try:
        return _build_exporting_provider(config)
    except Exception as error:
        _warn_exception(
            "Mercury CI could not configure OpenTelemetry; tracing is disabled "
            "for this job",
            error,
        )
        return None


def _warn(message: str) -> None:
    print(f"mercury_ci: warning: {message}", file=sys.stderr)


def _warn_exception(message: str, error: Exception) -> None:
    detail = str(error)
    summary = (
        type(error).__name__ if not detail else f"{type(error).__name__}: {detail}"
    )
    _warn(f"{message} ({summary})")


@dataclass(frozen=True)
class _OtlpHttpConfig:
    endpoint: str
    headers: dict[str, str]


def _otlp_http_config(env: Mapping[str, str]) -> _OtlpHttpConfig | None:
    if parse_bool(env.get("OTEL_SDK_DISABLED")):
        return None
    if (env.get("OTEL_TRACES_EXPORTER") or "").strip().lower() == "none":
        return None

    traces_endpoint = (env.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") or "").strip()
    generic_endpoint = (env.get("OTEL_EXPORTER_OTLP_ENDPOINT") or "").strip()
    if traces_endpoint:
        endpoint = traces_endpoint
    elif generic_endpoint:
        endpoint = f"{generic_endpoint.rstrip('/')}/v1/traces"
    else:
        return None

    protocol = (
        (
            env.get("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL")
            or env.get("OTEL_EXPORTER_OTLP_PROTOCOL")
            or "http/protobuf"
        )
        .strip()
        .lower()
    )
    if protocol != "http/protobuf":
        raise ValueError(
            f"Mercury CI only supports OTLP protocol 'http/protobuf'; got {protocol!r}"
        )
    headers = parse_env_headers(
        env.get("OTEL_EXPORTER_OTLP_TRACES_HEADERS")
        or env.get("OTEL_EXPORTER_OTLP_HEADERS")
        or "",
        liberal=True,
    )
    return _OtlpHttpConfig(
        endpoint=endpoint,
        headers=dict(headers),
    )


def should_export(env: Mapping[str, str]) -> bool:
    """Return whether the environment enables an OTLP endpoint."""
    return _otlp_http_config(env) is not None


def _build_sdk_provider() -> SdkTracerProvider:
    resource = Resource.create().merge(Resource({SERVICE_NAME: _SERVICE_NAME}))
    return SdkTracerProvider(resource=resource, shutdown_on_exit=False)


def _build_exporting_provider(config: _OtlpHttpConfig) -> SdkTracerProvider:
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
        OTLPSpanExporter,
    )

    provider = _build_sdk_provider()
    provider.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(
                endpoint=config.endpoint,
                headers=config.headers,
                timeout=_EXPORT_TIMEOUT_SECONDS,
            )
        )
    )
    return provider


@dataclass(frozen=True)
class TracerSetup:
    tracer: Tracer
    provider: TracerProvider | None
    owns_provider: bool


def build_tracer(
    *,
    env: Mapping[str, str],
    tracer_provider: TracerProvider | None = None,
) -> TracerSetup:
    """Build an exporting tracer only when configured or explicitly injected."""
    provider = tracer_provider
    owns_provider = False
    otlp_config = None if provider is not None else _otlp_http_config(env)
    if provider is None and otlp_config is not None:
        provider = _try_build_exporting_provider(otlp_config)
        owns_provider = provider is not None

    if provider is None:
        tracer = NoOpTracerProvider().get_tracer("mercury_ci")
    else:
        tracer = provider.get_tracer("mercury_ci")

    return TracerSetup(
        tracer=tracer,
        provider=provider,
        owns_provider=owns_provider,
    )
