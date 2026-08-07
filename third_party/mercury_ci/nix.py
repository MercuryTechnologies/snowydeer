# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Mapping host platforms to Nix system doubles."""

import os

_OS = {"Linux": "linux", "Darwin": "darwin"}
_ARCH = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64": "aarch64",
    "arm64": "aarch64",
}


def nix_system_for_host(sysname: str, machine: str) -> str | None:
    """Map `uname` `(sysname, machine)` to a Nix system double (e.g.
    `x86_64-linux`), or `None` when the host is unsupported."""
    os_part = _OS.get(sysname)
    arch_part = _ARCH.get(machine)
    if os_part is None or arch_part is None:
        return None
    return f"{arch_part}-{os_part}"


def host_nix_system() -> str | None:
    """The current host's Nix system double, or `None` if unsupported."""
    uname = os.uname()
    return nix_system_for_host(uname.sysname, uname.machine)
