# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

import argparse


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, add_help=False, fromfile_prefix_chars="@"
    )
    parser.add_argument(
        "--input",
        action="append",
        required=True,
        type=argparse.FileType("r"),
        help="each upload status",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=argparse.FileType("w"),
        help="upload result summary",
    )

    args = parser.parse_args()

    str = ""
    for f in args.input:
        content = f.read()
        str = "{}\n".format(content)
    print("{}".format(str), file=args.output)


if __name__ == "__main__":
    main()
