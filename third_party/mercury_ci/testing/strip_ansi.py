# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Remove terminal control sequences from captured test output."""

_ESC = "\x1b"
_ST = "\x9c"
_CSI = "\x9b"
_CONTROL_STRING_INTRODUCERS = frozenset({"]", "P", "X", "^", "_"})
_C1_CONTROL_STRING_INTRODUCERS = frozenset({"\x90", "\x98", "\x9d", "\x9e", "\x9f"})


def eat_terminal_codes(output: str) -> str:
    """Remove ECMA-48 terminal control sequences from captured output."""
    plain: list[str] = []
    offset = 0
    while offset < len(output):
        char = output[offset]
        if char == _ESC:
            offset = _eat_escape_sequence(output, offset + 1)
        elif char == _CSI:
            offset = _eat_csi(output, offset + 1)
        elif char in _C1_CONTROL_STRING_INTRODUCERS:
            offset = _eat_control_string(
                output,
                offset + 1,
                accepts_bell=char == "\x9d",
            )
        elif char in {"\a", "\r"} or 0x80 <= ord(char) <= 0x9F:
            offset += 1
        else:
            plain.append(char)
            offset += 1
    return "".join(plain)


def _eat_escape_sequence(output: str, offset: int) -> int:
    if offset >= len(output):
        return offset
    introducer = output[offset]
    if introducer == "[":
        return _eat_csi(output, offset + 1)
    if introducer in _CONTROL_STRING_INTRODUCERS:
        return _eat_control_string(
            output,
            offset + 1,
            accepts_bell=introducer == "]",
        )

    while offset < len(output) and 0x20 <= ord(output[offset]) <= 0x2F:
        offset += 1
    if offset < len(output) and 0x30 <= ord(output[offset]) <= 0x7E:
        offset += 1
    return offset


def _eat_csi(output: str, offset: int) -> int:
    while offset < len(output):
        value = ord(output[offset])
        if 0x40 <= value <= 0x7E:
            return offset + 1
        if not 0x20 <= value <= 0x3F:
            return offset
        offset += 1
    return offset


def _eat_control_string(
    output: str,
    offset: int,
    *,
    accepts_bell: bool,
) -> int:
    while offset < len(output):
        char = output[offset]
        if char == _ST or (accepts_bell and char == "\a"):
            return offset + 1
        if char == _ESC and output[offset : offset + 2] == f"{_ESC}\\":
            return offset + 2
        offset += 1
    return offset
