# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Test rule that verifies HaskellToolchainInfo.compiler_major_version matches
the actual GHC version reported by `ghc --numeric-version`.

This catches mistakes where the hardcoded version string in the toolchain
definition drifts from the real compiler version (which causes obscure
linker errors like: ld.gold: error: cannot find -lHS...-ghc9.10.3).
"""

load(
    "@buck2-haskell//:toolchain.bzl",
    "HaskellToolchainInfo",
)

def _ghc_version_check_test_impl(ctx: AnalysisContext) -> list[Provider]:
    toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    expected_version = toolchain.compiler_major_version
    ghc = toolchain.compiler

    test_script = ctx.actions.declare_output("ghc_version_check.sh")
    script_content = """\
#!/usr/bin/env bash
set -euo pipefail
expected="$1"
actual="$("$2" --numeric-version)"
if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: compiler_major_version mismatch" >&2
    echo "  HaskellToolchainInfo.compiler_major_version = $expected" >&2
    echo "  ghc --numeric-version                       = $actual" >&2
    echo "" >&2
    echo "Update compiler_major_version in toolchains/nix/nix_haskell_toolchain.bzl" >&2
    exit 1
fi
echo "OK: compiler_major_version ($expected) matches ghc --numeric-version ($actual)"
"""
    ctx.actions.write(test_script, script_content, is_executable = True)

    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(
            type = "ghc_version_check",
            command = [cmd_args(test_script), expected_version, ghc],
            labels = ["fast"],
            local_resources = {},
        ),
    ]

ghc_version_check_test = rule(
    impl = _ghc_version_check_test_impl,
    attrs = {
        "_haskell_toolchain": attrs.toolchain_dep(
            providers = [HaskellToolchainInfo],
            default = "toolchains//:haskell",
        ),
    },
)
