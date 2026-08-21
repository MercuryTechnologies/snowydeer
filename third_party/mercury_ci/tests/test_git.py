# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for `mercury_ci.git`."""

import os
from pathlib import Path

import pytest

from mercury_ci.actions import CommandResult
from mercury_ci.git import (
    Git,
    GitStatusEntry,
    StatusCode,
    UntrackedMode,
    parse_status_z,
)
from mercury_ci.testing import RecordingCiActions


def _status_bytes(*records: bytes) -> bytes:
    return b"\0".join(records) + b"\0"


def test_modified_and_untracked() -> None:
    entries = parse_status_z(_status_bytes(b" M src/main.py", b"?? new.txt"))
    assert len(entries) == 2
    assert (entries[0].index_status, entries[0].worktree_status) == (
        StatusCode.UNMODIFIED,
        StatusCode.MODIFIED,
    )
    assert entries[0].path == Path("src/main.py")
    assert entries[0].affected_paths == [Path("src/main.py")]
    assert (entries[1].index_status, entries[1].worktree_status) == (
        StatusCode.UNTRACKED,
        StatusCode.UNTRACKED,
    )
    assert entries[1].path == Path("new.txt")


def test_rename_includes_both_paths() -> None:
    # -z reverses to `dest\0src`; unusual names carry spaces and newlines.
    entries = parse_status_z(
        _status_bytes(b"R  new name.txt", b"old\nname.txt", b" M other")
    )
    assert len(entries) == 2
    rename = entries[0]
    assert rename.is_rename
    assert rename.path == Path("new name.txt")
    assert rename.orig_path == Path("old\nname.txt")
    assert rename.affected_paths == [Path("old\nname.txt"), Path("new name.txt")]
    assert entries[1].path == Path("other")


def test_copy_affects_only_destination() -> None:
    # A copy leaves the source in place, so only the destination is affected,
    # even though the source token is still parsed into orig_path.
    entries = parse_status_z(_status_bytes(b"C  dest", b"source"))
    copy = entries[0]
    assert copy.is_copy
    assert copy.orig_path == Path("source")
    assert copy.affected_paths == [Path("dest")]


def test_non_utf8_filename_round_trips() -> None:
    entries = parse_status_z(_status_bytes(b"?? bad\xffname"))
    assert entries[0].path == Path(os.fsdecode(b"bad\xffname"))


def test_rename_missing_source_raises() -> None:
    with pytest.raises(ValueError):
        parse_status_z(b"R  dest\0")


def test_missing_space_at_byte_2_raises() -> None:
    # XY must be followed by a space; XY?path would silently misparse the path.
    with pytest.raises(ValueError):
        parse_status_z(b" M?foo\0")


def test_empty_output() -> None:
    assert parse_status_z(b"") == []


def test_git_status_command_shape_and_parse() -> None:
    data = _status_bytes(b"R  new", b"old", b"?? u")

    def handler(args: list[str]) -> CommandResult:
        return CommandResult(0, args, data, b"")

    actions = RecordingCiActions(subprocess_handler=handler)
    assert Git(actions).affected_paths(UntrackedMode.ALL) == [
        Path("old"),
        Path("new"),
        Path("u"),
    ]
    assert actions.subprocess_invocation_args[0] == [
        "git",
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
    ]


def test_invalid_untracked_mode_raises() -> None:
    with pytest.raises(ValueError):
        UntrackedMode("sometimes")


def test_untracked_mode_forwarded() -> None:
    actions = RecordingCiActions(
        subprocess_handler=lambda args: CommandResult(0, args, b"", b"")
    )
    Git(actions).status(UntrackedMode.NO)
    assert "--untracked-files=no" in actions.subprocess_invocation_args[0]


def test_plain_entry_affected_paths() -> None:
    entry = GitStatusEntry(StatusCode.ADDED, StatusCode.UNMODIFIED, Path("added.py"))
    assert not entry.is_rename
    assert not entry.is_copy
    assert entry.affected_paths == [Path("added.py")]
