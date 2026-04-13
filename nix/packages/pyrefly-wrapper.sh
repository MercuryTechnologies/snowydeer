# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# shellcheck shell=bash

if (( "$#" < 1 )); then
    >&2 echo "$0: Not enough args"
    exit 1
fi

if [[ "$1" != "check" ]]; then
    >&2 echo "$0: First argument must be 'check' for nonsense reasons
buck2-prelude (old versions) pass 'check' as the first argument.
If you upgraded the buck2-prelude, you may need to change this wrapper."
    exit 1
fi

shift

pyrefly buck-check "$@"
