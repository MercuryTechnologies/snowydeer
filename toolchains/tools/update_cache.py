# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

import argparse
import sys
import subprocess


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, add_help=False, fromfile_prefix_chars="@"
    )
    parser.add_argument(
        "--hook",
        required=True,
        type=str,
        help="cache hook",
    )
    parser.add_argument(
        "--input",
        required=True,
        type=str,
        help="all nix paths",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=argparse.FileType("w"),
        help="upload result summary",
    )

    args = parser.parse_args()

    cmd = [args.hook, args.input]
    ret_code = subprocess.check_call(
        cmd,
        stdout=sys.stderr.buffer,
    )
    print("ret_code = {}".format(ret_code), file=args.output)


if __name__ == "__main__":
    main()
