# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Executable entry point for target-determined Buck2 CI."""

from mercury_ci.btd_ci import cli_main


if __name__ == "__main__":
    cli_main()
