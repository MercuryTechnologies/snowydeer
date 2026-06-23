#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# template for GHCi

set -eo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)

# Change to the project root so GHCi writes interface files and history there
# rather than in buck-out. All script-internal paths use $DIR which is absolute.
cd "$(git -C "$DIR" rev-parse --show-toplevel)"

# binutils_path: <binutils_path>
# ghci_lib_path: <ghci_lib_path>
# cc_path: <cc_path>
# cpp_path: <cpp_path>
# cxx_path: <cxx_path>
# ghci_packager: <ghci_packager>
# ghci_ghc_path: <ghci_ghc_path>

# Add plugin tools to PATH if present
PLUGIN_TOOLS_DIR="$DIR/<name>.plugin-tools"
if [ -d "$PLUGIN_TOOLS_DIR" ]; then
  export PATH="$PLUGIN_TOOLS_DIR:$PATH"
fi

# Pass native C libraries declared via native_deps as explicit GHCi arguments
# so they are loaded via loadDLL (RTLD_NOW|RTLD_GLOBAL), making FFI symbols
# (e.g. uuid_generate_time) visible to the RTS bytecode linker.
# The build rule symlinks these SOs into ${DIR}/native_libs/.
_NATIVE_LIB_ARGS=()
if [ -d "${DIR}/native_libs" ]; then
  for _lib in "${DIR}/native_libs/"*; do
    [ -f "${_lib}" ] && _NATIVE_LIB_ARGS+=("${_lib}")
  done
fi

# Exposed packages: use an @-args-file when present (global rule writes one to
# support GHC package-renaming syntax that contains '(' which bash would
# misinterpret if inlined).  Regular ghci rule uses the inline <exposed_packages>.
_EP_ARGS=()
[ -f "${DIR}/exposed_packages.args" ] && _EP_ARGS+=("@${DIR}/exposed_packages.args")

# Parallel module compilation: use half the available cores, capped at 20.
# Override by setting GHCI_JOBS in your environment before running.
# Mirrors the formula used by mwb-cabal-repl.
if [[ ! -v GHCI_JOBS ]]; then
  GHCI_JOBS=$(( $(nproc) / 2 ))
  if [[ "$GHCI_JOBS" -gt 20 ]]; then GHCI_JOBS=20; fi
  if [[ "$GHCI_JOBS" -lt 1 ]]; then GHCI_JOBS=1; fi
fi

mkdir -p .hiefiles

# -fwrite-if-simplified-core writes the simplifier output into interface files so
# GHCi can skip typechecking+simplification on subsequent restarts (near-instant
# reloads). -hisuf ghci_hi prevents clobbering interface files from regular builds.
mkdir -p .ghci-interfaces

exec <user_ghci_path> @${DIR}/toolchain_pkgdbs.args <package_dbs> "${_EP_ARGS[@]}" <exposed_packages> <compiler_flags> -fwrite-ide-info -hiedir .hiefiles -fwrite-interface -fwrite-if-simplified-core -hisuf ghci_hi -hidir .ghci-interfaces -j"$GHCI_JOBS" +RTS -A1G -n2m -RTS <dep_srcs_flag> <srcs> -ghci-script "$DIR/<start_ghci>" "${_NATIVE_LIB_ARGS[@]}" "$DIR/<squashed_so>" "$@"
