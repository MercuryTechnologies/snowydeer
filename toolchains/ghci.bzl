# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
FIXME: please write a docstring here describing what this module is for
"""

load(
    "@buck2-haskell//:toolchain.bzl",
    "HaskellToolchainInfo",
    "haskell_toolchain",
)

def _ghci_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    out = ctx.actions.write(
        "ghci",
        [
            "#!/usr/bin/env bash",
            cmd_args(haskell_toolchain.compiler, format = """exec {} --interactive "$@" """),
        ],
        is_executable = True,
    )
    return [
        DefaultInfo(out),
        RunInfo(cmd_args(out, hidden = [haskell_toolchain.compiler])),
    ]

ghci = rule(
    impl = _ghci_impl,
    attrs = {
        "_haskell_toolchain": haskell_toolchain(),
    },
)
