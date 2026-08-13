# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# shellcheck shell=bash

if (("$#" < 1)); then
  >&2 echo "$0: Not enough args"
  exit 1
fi

pyrefly buck-check "$@"
