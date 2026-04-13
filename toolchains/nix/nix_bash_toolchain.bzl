# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Genrule toolchain: does ... basically nothing. It surely should provide bash,
but it doesn't do that in buck2.
"""

load("@prelude//genrule_toolchain.bzl", "GenruleToolchainInfo")

def nix_bash_genrule_toolchain_impl(_ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        GenruleToolchainInfo(),
    ]

nix_bash_genrule_toolchain = rule(
    impl = nix_bash_genrule_toolchain_impl,
    attrs = {},
    is_toolchain_rule = True,
)
