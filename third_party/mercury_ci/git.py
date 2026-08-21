# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Robust `git` wrappers and models."""

import os
from dataclasses import dataclass
from pathlib import Path
import enum
import re
import dataclasses

from mercury_ci.actions import AbstractCiActions


class UntrackedMode(enum.Enum):
    NO = "no"
    """Show no untracked files"""
    NORMAL = "normal"
    """Show untracked files and directories, but not contents"""
    ALL = "all"
    """Show files within untracked directories too"""


class StatusCode(enum.Enum):
    """
    A single-character `git status --porcelain=v1` status code.

    See: <https://git-scm.com/docs/git-status#_output>
    """

    UNMODIFIED = " "
    MODIFIED = "M"
    FILE_TYPE_CHANGED = "T"
    ADDED = "A"
    DELETED = "D"
    RENAMED = "R"
    COPIED = "C"
    UNMERGED = "U"
    UNTRACKED = "?"
    IGNORED = "!"


_RENAME_COPY = frozenset({StatusCode.RENAMED, StatusCode.COPIED})


@dataclass(frozen=True, slots=True)
class GitStatusEntry:
    """One `git status --porcelain=v1` entry.

    `index_status`/`worktree_status` are the staged and unstaged status codes;
    `path` is the destination and `orig_path` the source for a rename/copy.
    """

    index_status: StatusCode
    worktree_status: StatusCode
    path: Path
    orig_path: Path | None = None

    @property
    def is_rename(self) -> bool:
        return (
            self.index_status == StatusCode.RENAMED
            or self.worktree_status == StatusCode.RENAMED
        )

    @property
    def is_copy(self) -> bool:
        return (
            self.index_status == StatusCode.COPIED
            or self.worktree_status == StatusCode.COPIED
        )

    @property
    def affected_paths(self) -> list[Path]:
        # A rename removes the source and adds the destination; a copy leaves
        # the source untouched, so only the destination is affected.
        if self.is_rename and self.orig_path is not None:
            return [self.orig_path, self.path]
        return [self.path]


def parse_status_z(data: bytes) -> list[GitStatusEntry]:
    """Parse `git status --porcelain=v1 -z` output.

    NUL framing keeps filenames with spaces or newlines unambiguous. In `-z`
    mode a rename/copy record is `XY dest\\0src`, so the source is the token
    following the entry. Paths are `os.fsdecode`d so non-UTF-8 names survive.
    """
    tokens = data.split(b"\0")
    if tokens and tokens[-1] == b"":
        tokens.pop()

    entries: list[GitStatusEntry] = []
    index = 0
    while index < len(tokens):
        record = tokens[index]
        index += 1
        if len(record) < 4 or record[2] != ord(" "):
            raise ValueError(f"malformed git status record: {record!r}")
        index_status = StatusCode(chr(record[0]))
        worktree_status = StatusCode(chr(record[1]))
        path = Path(os.fsdecode(record[3:]))
        orig_path: Path | None = None
        if index_status in _RENAME_COPY or worktree_status in _RENAME_COPY:
            if index >= len(tokens):
                raise ValueError(f"rename/copy record missing source path: {record!r}")
            orig_path = Path(os.fsdecode(tokens[index]))
            index += 1
        entries.append(GitStatusEntry(index_status, worktree_status, path, orig_path))
    return entries


@dataclass(frozen=True, slots=True)
class Git:
    """A thin `git` wrapper over `AbstractCiActions`."""

    actions: AbstractCiActions

    def status(
        self, untracked_files: UntrackedMode = UntrackedMode.ALL
    ) -> list[GitStatusEntry]:
        result = self.actions.run_subprocess(
            [
                "git",
                "status",
                "--porcelain=v1",
                "-z",
                f"--untracked-files={untracked_files.value}",
            ],
            capture_output=True,
        )
        return parse_status_z(result.stdout)

    def affected_paths(
        self, untracked_files: UntrackedMode = UntrackedMode.ALL
    ) -> list[Path]:
        paths: list[Path] = []
        for entry in self.status(untracked_files):
            paths.extend(entry.affected_paths)
        return paths


@dataclasses.dataclass(frozen=True, slots=True)
class GitObjectId:
    """A validated hexadecimal Git object ID."""

    value: str

    def __post_init__(self) -> None:
        if not re.fullmatch(r"[0-9a-fA-F]{7,64}", self.value):
            raise ValueError(f"not a Git object ID: {self.value!r}")

    def __str__(self) -> str:
        return self.value
