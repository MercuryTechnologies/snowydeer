#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc
#
# SPDX-License-Identifier: MIT OR Apache-2.0

set -exuo pipefail

store_path=$(cat "$1")
# the binary should obviously be executable!
[[ -x $store_path/bin/hello ]]
# ensure the binary has no working-directory dependence
[[ "$(cd "${TMPDIR:-/tmp}"; "$store_path"/bin/hello)" == "Hello world" ]]
