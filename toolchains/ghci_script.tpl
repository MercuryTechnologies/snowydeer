# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# template for GHCi

set -eo pipefail

DIR=$(dirname "$0")

# binutils_path: <binutils_path>
# ghci_lib_path: <ghci_lib_path>
# cc_path: <cc_path>
# cpp_path: <cpp_path>
# cxx_path: <cxx_path>
# ghci_packager: <ghci_packager>
# ghci_ghc_path: <ghci_ghc_path>

exec <user_ghci_path> <package_dbs> -ghci-script "$DIR/<start_ghci>" "$DIR/<squashed_so>" "$@"
