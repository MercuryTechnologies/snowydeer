# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Injection-safe writing of GitHub Actions step outputs (`$GITHUB_OUTPUT`).

See: <https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#multiline-strings>
"""

import os
import re
from collections.abc import Callable
from pathlib import Path

_OUTPUT_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
_DELIMITER_BASE = "GHOUTPUT_EOF"


def _make_delimiter(value: str) -> str:
    # Absence as a substring guarantees no line of `value` equals the delimiter,
    # so the value cannot terminate the heredoc early or inject an output.
    delimiter = _DELIMITER_BASE
    counter = 0
    while delimiter in value:
        counter += 1
        delimiter = f"{_DELIMITER_BASE}_{counter}"
    return delimiter


def _path_writer(output_path: Path | None) -> Callable[[str], None]:
    if output_path is None:
        env = os.environ.get("GITHUB_OUTPUT")
        if not env:
            raise ValueError("GITHUB_OUTPUT is not set; pass output_path explicitly")
        output_path = Path(env)

    def _write(content: str) -> None:
        with output_path.open("a", encoding="utf-8") as handle:  # type: ignore[union-attr]
            handle.write(content)

    return _write


def write_output(
    name: str,
    value: str,
    output_path: Path | None = None,
    *,
    _writer: Callable[[str], None] | None = None,
) -> None:
    """Append `name=value` to `$GITHUB_OUTPUT` (or `output_path`) as a heredoc.

    The name is restricted to a safe identifier and the value is written with a
    delimiter that cannot appear in it, so no value content (`=`, newlines, a
    delimiter-looking line) can inject further outputs.

    `_writer` is for testing: pass a callable that receives the fully-formatted
    heredoc string instead of writing to a file.
    """
    if not _OUTPUT_NAME_RE.fullmatch(name):
        raise ValueError(f"invalid GitHub output name: {name!r}")
    if "\0" in value:
        raise ValueError("GitHub output value must not contain a NUL byte")

    writer = _writer if _writer is not None else _path_writer(output_path)
    delimiter = _make_delimiter(value)
    writer(f"\n{name}<<{delimiter}\n{value}\n{delimiter}\n")
