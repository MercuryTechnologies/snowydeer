# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Centralized CI runner labels, so workflows reference one source of truth."""

from dataclasses import dataclass

LINUX_ARM = "namespace-profile-mwb-build-arm"
"""Runner label for aarch64 Linux builds."""

LINUX_X86_64 = "namespace-profile-mwb-build"
"""Runner label for x86_64 Linux builds. NOTE: this is not a large enough runner to build the entire mwb."""

MACOS = "ghcr.io/cirruslabs/macos-runner:sequoia"
"""Runner image for macOS builds."""

ALL_RUNNERS = (LINUX_ARM, LINUX_X86_64, MACOS)


@dataclass(frozen=True, slots=True)
class CiPlatform:
    """A supported Nix system and its Buck/GitHub runner representation."""

    nix_system: str
    runner: str
    fake_host: str
    fake_arch: str


AARCH64_LINUX = CiPlatform("aarch64-linux", LINUX_ARM, "linux", "aarch64")
X86_64_LINUX = CiPlatform("x86_64-linux", LINUX_X86_64, "linux", "x8664")
AARCH64_DARWIN = CiPlatform("aarch64-darwin", MACOS, "macos", "aarch64")

CI_PLATFORMS = [AARCH64_LINUX, X86_64_LINUX, AARCH64_DARWIN]
