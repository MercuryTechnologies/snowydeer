# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Centralized CI runner labels, so workflows reference one source of truth."""

LINUX_ARM = "ubuntu-latest-arm-xlarge"
"""Runner label for aarch64 Linux builds."""

LINUX_X86_64 = "nixos-xlarge"
"""Runner label for x86_64 Linux builds. NOTE: this is not a large enough runner to build the entire mwb."""

MACOS = "ghcr.io/cirruslabs/macos-runner:sequoia"
"""Runner image for macOS builds."""

ALL_RUNNERS = (LINUX_ARM, LINUX_X86_64, MACOS)
