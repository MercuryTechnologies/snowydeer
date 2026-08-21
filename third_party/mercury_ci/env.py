# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Environment-value parsing helpers for Mercury CI."""

_TRUE_STRINGS = frozenset({"1", "true", "yes", "on"})


def parse_bool(value: str | None) -> bool:
    """Parse the conventional truthy environment-variable spellings."""
    return value is not None and value.strip().lower() in _TRUE_STRINGS
