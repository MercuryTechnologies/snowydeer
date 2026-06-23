# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

import argparse
import json
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__, fromfile_prefix_chars="@")
    parser.add_argument(
        "--output",
        required=True,
        type=argparse.FileType("w"),
        help="Write package metadata to this file in JSON format.",
    )
    parser.add_argument(
        "--flake", required=True, type=str, help="A flake URL, such as `path:dir/nix`."
    )

    args = parser.parse_args()

    out = subprocess.check_output(
        [
            "nix",
            "eval",
            "--json",
            # this only really matters for IFD but let's do it anyway
            "--print-build-logs",
            "--show-trace",
            # --no-update-lock-file: if the flake.lock file does not match the flake.nix, error out.
            # This prevents highly baffling behaviour that should be done by the user rather than by buck2.
            "--no-update-lock-file",
            # Don't use flake registries if someone omits something from `inputs.*` but puts it in `outputs` args.
            "--no-use-registries",
            args.flake,
        ]
    )

    drvs = json.loads(out).values()

    subprocess.run(
        ["nix", "derivation", "show", "--stdin"],
        input="\n".join(f"{p}^*" for p in sorted(drvs)),
        text=True,
        check=True,
        stdout=args.output,
    )


if __name__ == "__main__":
    main()
