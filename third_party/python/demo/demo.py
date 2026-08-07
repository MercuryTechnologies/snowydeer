# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Demo of buck2 Python dependencies.
"""

import requests


def main():
    robots = requests.get("https://google.com/robots.txt").text
    print("google.com robots.txt:\n" + robots)


if __name__ == "__main__":
    main()
