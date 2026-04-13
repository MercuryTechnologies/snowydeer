# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

import argparse
import os


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, add_help=False, fromfile_prefix_chars="@"
    )
    parser.add_argument(
        "--input",
        action="append",
        required=True,
        type=str,
        help="package name",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=argparse.FileType("w"),
        help="Create required output file.",
    )

    args = parser.parse_args()

    nix_paths = []
    for out_link in args.input:
        nix_path = os.readlink(out_link)
        nix_paths.append(nix_path)

    for p in nix_paths:
        print(p, file=args.output)


if __name__ == "__main__":
    main()
