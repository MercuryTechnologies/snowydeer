# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""OpenTelemetry recording and snapshot helpers for Mercury CI tests."""

import json
import pathlib
import re
from collections import defaultdict
from collections.abc import Sequence
from typing import Any

import expecttest
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)
from opentelemetry.semconv._incubating.attributes import process_attributes
from opentelemetry.trace import SpanKind


_PYTHON_EXECUTABLE = re.compile(
    r"python(?:\d+(?:\.\d+)*)?(?:[dt])?(?:\.exe)?", re.IGNORECASE
)


class RecordingSpanExporter(InMemorySpanExporter):
    """An in-memory exporter with stable, human-readable span snapshots."""

    def assert_finished_spans(self, expected: expecttest.Expect) -> None:
        expected.assert_expected(_render_span_tree(self.get_finished_spans()))


def recording_provider() -> tuple[TracerProvider, RecordingSpanExporter]:
    """Build a non-global provider whose completed spans can be asserted."""
    exporter = RecordingSpanExporter()
    provider = TracerProvider(shutdown_on_exit=False)
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    return provider, exporter


def _render_span_tree(spans: Sequence[ReadableSpan]) -> str:
    roots = [span for span in spans if span.parent is None]
    root_ids = {span.context.span_id for span in roots if span.context is not None}
    span_labels = _span_labels(spans)
    lines: list[str] = []
    for span in sorted(spans, key=_span_sort_key):
        attributes = _normalized_attributes(span)
        if span.parent is None:
            parent = "<none>"
        elif len(roots) == 1 and span.parent.span_id in root_ids:
            parent = "<root>"
        else:
            parent = span_labels.get(span.parent.span_id, "<external>")
        label = span_labels[span.context.span_id]
        lines.append(
            f"{label} [{span.kind.name}/{span.status.status_code.name}] parent={parent}"
        )
        lines.extend(
            f"  {attribute} = {json.dumps(value, sort_keys=True)}"
            for attribute, value in sorted(attributes.items())
        )
    return "\n".join(lines) + "\n"


def _normalized_name(span: ReadableSpan) -> str:
    if span.kind is not SpanKind.CLIENT:
        return span.name
    attributes = span.attributes or {}
    executable_name = attributes.get(process_attributes.PROCESS_EXECUTABLE_NAME)
    return _basename(executable_name) if executable_name is not None else span.name


def _span_labels(spans: Sequence[ReadableSpan]) -> dict[int, str]:
    spans_by_name: dict[str, list[ReadableSpan]] = defaultdict(list)
    for span in spans:
        spans_by_name[_normalized_name(span)].append(span)

    labels: dict[int, str] = {}
    for name, same_named_spans in spans_by_name.items():
        same_named_spans.sort(
            key=lambda span: (span.start_time or 0, span.end_time or 0)
        )
        for position, span in enumerate(same_named_spans, start=1):
            if span.context is not None:
                labels[span.context.span_id] = (
                    f"{name}#{position}" if len(same_named_spans) > 1 else name
                )
    return labels


def _normalized_attributes(span: ReadableSpan) -> dict[str, Any]:
    attributes = dict(span.attributes or {})
    if span.kind is SpanKind.CLIENT:
        args = list(attributes.get(process_attributes.PROCESS_COMMAND_ARGS, ()))
        if args:
            args[0] = _basename(args[0])
            attributes[process_attributes.PROCESS_COMMAND_ARGS] = args
        if process_attributes.PROCESS_EXECUTABLE_NAME in attributes:
            attributes[process_attributes.PROCESS_EXECUTABLE_NAME] = _basename(
                attributes[process_attributes.PROCESS_EXECUTABLE_NAME]
            )
        if process_attributes.PROCESS_EXECUTABLE_PATH in attributes:
            executable_path = pathlib.Path(
                str(attributes[process_attributes.PROCESS_EXECUTABLE_PATH])
            )
            attributes[process_attributes.PROCESS_EXECUTABLE_PATH] = (
                f"<absolute>/{_basename(executable_path)}"
                if executable_path.is_absolute()
                else _basename(executable_path)
            )
        if process_attributes.PROCESS_WORKING_DIRECTORY in attributes:
            working_directory = pathlib.Path(
                str(attributes[process_attributes.PROCESS_WORKING_DIRECTORY])
            )
            attributes[process_attributes.PROCESS_WORKING_DIRECTORY] = (
                "<absolute>"
                if working_directory.is_absolute()
                else str(working_directory)
            )
        if process_attributes.PROCESS_PID in attributes:
            attributes[process_attributes.PROCESS_PID] = "<pid>"
    return attributes


def _basename(value: Any) -> str:
    basename = pathlib.Path(str(value)).name
    return "python" if _PYTHON_EXECUTABLE.fullmatch(basename) else basename


def _span_sort_key(span: ReadableSpan) -> tuple[bool, bool, int, str]:
    attributes = span.attributes or {}
    return (
        span.parent is not None,
        span.kind is not SpanKind.INTERNAL,
        int(attributes.get(process_attributes.PROCESS_EXIT_CODE, -1)),
        span.name,
    )
