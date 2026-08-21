# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""W3C trace-context propagation over process environment variables."""

from collections.abc import Mapping

from opentelemetry.context import Context
from opentelemetry.trace import Span, set_span_in_context
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

ENV_TRACEPARENT = "TRACEPARENT"
ENV_TRACESTATE = "TRACESTATE"
_CARRIER_TRACEPARENT = "traceparent"
_CARRIER_TRACESTATE = "tracestate"
_PROPAGATOR = TraceContextTextMapPropagator()


def parent_context_from_env(env: Mapping[str, str]) -> Context:
    """Extract inherited W3C context from uppercase environment variables."""
    carrier: dict[str, str] = {}
    if traceparent := env.get(ENV_TRACEPARENT):
        carrier[_CARRIER_TRACEPARENT] = traceparent
    if tracestate := env.get(ENV_TRACESTATE):
        carrier[_CARRIER_TRACESTATE] = tracestate
    return _PROPAGATOR.extract(carrier)


def child_env(span: Span, base_env: Mapping[str, str]) -> dict[str, str]:
    """Copy an environment and propagate `span` using uppercase keys."""
    result = dict(base_env)
    result.pop(_CARRIER_TRACEPARENT, None)
    result.pop(_CARRIER_TRACESTATE, None)
    if not span.get_span_context().is_valid:
        return result

    result.pop(ENV_TRACEPARENT, None)
    result.pop(ENV_TRACESTATE, None)
    carrier: dict[str, str] = {}
    _PROPAGATOR.inject(carrier, context=set_span_in_context(span))
    if traceparent := carrier.get(_CARRIER_TRACEPARENT):
        result[ENV_TRACEPARENT] = traceparent
    if tracestate := carrier.get(_CARRIER_TRACESTATE):
        result[ENV_TRACESTATE] = tracestate
    return result
