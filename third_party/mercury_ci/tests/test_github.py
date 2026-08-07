# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for `mercury_ci.github.write_output`."""

import re
from pathlib import Path

import pytest
from hypothesis import given, strategies as st

from mercury_ci.github import write_output

_valid_name = st.from_regex(r"[A-Za-z_][A-Za-z0-9_-]*", fullmatch=True)
_valid_value = st.text(alphabet=st.characters(blacklist_characters="\x00"))
_invalid_name = st.text().filter(
    lambda n: not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", n)
)


def _capture(name: str, value: str) -> str:
    written: list[str] = []
    write_output(name, value, _writer=written.append)
    (content,) = written
    return content


@given(_valid_name, _valid_value)
def test_output_is_exact_heredoc(name: str, value: str) -> None:
    # Covers: single-line, multiline, CRLF, equals-in-value — any value is
    # written verbatim between the heredoc delimiters.
    content = _capture(name, value)
    delimiter = content.partition("<<")[2].split("\n", 1)[0]
    assert content == f"\n{name}<<{delimiter}\n{value}\n{delimiter}\n"


@given(_valid_name, _valid_value)
def test_delimiter_never_in_value(name: str, value: str) -> None:
    # Security invariant: a chosen delimiter that appears in `value` would let
    # the value terminate the heredoc early and inject further outputs.
    content = _capture(name, value)
    delimiter = content.partition("<<")[2].split("\n", 1)[0]
    assert delimiter not in value


def test_delimiter_looking_value_escalates() -> None:
    # A value that contains both the base delimiter and its first escalation
    # forces exactly two levels of escalation.
    value = "GHOUTPUT_EOF\nGHOUTPUT_EOF_1\ninner"
    content = _capture("k", value)
    delimiter = content.partition("<<")[2].split("\n", 1)[0]
    assert delimiter == "GHOUTPUT_EOF_2"
    assert delimiter not in value
    assert content.endswith(f"\n{delimiter}\n")


@given(_invalid_name, _valid_value)
def test_rejects_invalid_names(name: str, value: str) -> None:
    with pytest.raises(ValueError):
        write_output(name, value, _writer=lambda _: None)


@given(
    _valid_name,
    st.text(alphabet=st.characters(blacklist_characters="\x00")),
    st.text(alphabet=st.characters(blacklist_characters="\x00")),
)
def test_rejects_nul_in_value(name: str, prefix: str, suffix: str) -> None:
    with pytest.raises(ValueError):
        write_output(name, prefix + "\x00" + suffix, _writer=lambda _: None)


def test_defaults_to_github_output_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    out = tmp_path / "gh_out"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    write_output("k", "v")
    assert out.read_text(encoding="utf-8") == "\nk<<GHOUTPUT_EOF\nv\nGHOUTPUT_EOF\n"


def test_missing_env_is_a_clear_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    with pytest.raises(ValueError):
        write_output("k", "v")
