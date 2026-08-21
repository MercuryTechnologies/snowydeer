# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for `mercury_ci.labels`."""

from mercury_ci.labels import find_undocumented_labels


def test_finds_labels_without_level_two_heading() -> None:
    target_attributes = [
        {"labels": ["documented", "missing"]},
        {"labels": ["missing", "also_missing"]},
        {},
    ]
    documentation = """# Labels

## `documented`

### `missing`
"""

    assert find_undocumented_labels(target_attributes, documentation) == [
        "also_missing",
        "missing",
    ]


def test_accepts_documented_labels() -> None:
    target_attributes = [{"labels": ["first", "second"]}]
    documentation = """## `first`

## `second`
"""

    assert find_undocumented_labels(target_attributes, documentation) == []
