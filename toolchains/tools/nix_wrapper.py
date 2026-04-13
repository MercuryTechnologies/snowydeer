#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Wrapper script to call nix"""

import argparse
import os
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, add_help=False, fromfile_prefix_chars="@"
    )
    parser.add_argument(
        "--buck2-output",
        required=True,
        help="Output link",
    )

    args, nix_args = parser.parse_known_args()
    cmd = [
        "nix",
        *nix_args,
        "--print-build-logs",
        "--show-trace",
        # --no-update-lock-file: if the flake.lock file does not match the flake.nix, error out.
        # This prevents highly baffling behaviour that should be done by the user rather than by buck2.
        "--no-update-lock-file",
        # Don't use flake registries if someone omits something from `inputs.*` but puts it in `outputs` args.
        "--no-use-registries",
        "--out-link",
        args.buck2_output,
    ]

    # NOTE 1: We time-out nix build.
    # We assume nix dependencies are all already previously populated
    # in the cache in update cache CI.
    # If we can detect the nix cache-miss more directly from the Nix CLI
    # interface, that would be better though the timeout test is
    # practically useful.

    # disabled for now until nix cache problem solved.
    # timeout_seconds = 30

    # NOTE 2: Buck2 swallows stdout on successful builds.
    # Redirect to stderr to avoid this.
    returncode = subprocess.check_call(
        cmd,
        stderr=sys.stderr.buffer,  # timeout=timeout_seconds # TODO: disabled for now until nix cache problem solved
    )

    if returncode != 0:
        return returncode

    does_exist = os.path.exists(args.buck2_output)
    if not does_exist:
        time.sleep(1)
        # Second chance. This is a work-around for the issue [DUX-3095]
        # which is observed on MacOS; nix build --out-link does not create
        # output symlink needed for Buck2, and exit with exit code 0.
        # The issue is largely resolved by running nix build once more.
        # TODO: Fix Nix or wherever the root cause exists.
        returncode2 = subprocess.check_call(
            cmd,
            stdout=sys.stderr.buffer,  # timeout=timeout_seconds # disabled for now until nix cache problem solved
        )
        does_exist_2 = os.path.exists(args.buck2_output)
        print("does it exist after re-run? : {}".format(does_exist_2), file=sys.stderr)
        return returncode2

    return 0


if __name__ == "__main__":
    main()
