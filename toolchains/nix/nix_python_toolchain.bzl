# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Toolchain for Python using an interpreter from Nix.
"""

load("@prelude//python:manifest.bzl", "create_manifest_for_entries")
load("@prelude//python:toolchain.bzl", "PythonPlatformInfo", "PythonToolchainInfo")
load("@prelude//python_bootstrap:python_bootstrap.bzl", "PythonBootstrapToolchainInfo")

def _nix_python_bootstrap_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        PythonBootstrapToolchainInfo(
            interpreter = ctx.attrs.interpreter[RunInfo].args,
        ),
    ]

nix_python_bootstrap_toolchain = rule(
    impl = _nix_python_bootstrap_toolchain_impl,
    attrs = {
        "interpreter": attrs.dep(
            providers = [RunInfo],
            default = "//:python_bootstrap_interpreter",
        ),
    },
    is_toolchain_rule = True,
)

def _nix_python_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    manifest_info = create_manifest_for_entries(ctx, "stub", [])
    return [
        DefaultInfo(),
        PythonToolchainInfo(
            interpreter = ctx.attrs.interpreter[RunInfo].args,
            version = ctx.attrs.version,
            host_interpreter = ctx.attrs.interpreter[RunInfo],  # Hmm.
            compile = RunInfo(args = ["echo", "COMPILEINFO"]),  # ???
            package_style = "inplace",
            pex_extension = ctx.attrs.pex_extension,
            native_link_strategy = "separate",
            type_checker = ctx.attrs.type_checker[RunInfo],
            typeshed_stubs = manifest_info,
        ),
        PythonPlatformInfo(name = ctx.attrs.platform),
    ]

nix_python_toolchain = rule(
    impl = _nix_python_toolchain_impl,
    attrs = {
        "interpreter": attrs.dep(providers = [RunInfo], default = "//:python_bootstrap_interpreter"),
        "version": attrs.option(attrs.string(), default = None),
        # NOTE: The buck2-prelude is written with the undocumented expectation
        # that the `type_checker` is `pyrefly`, as evidenced by the fact that
        # instead of passing source file paths to the typechecker it passes a
        # JSON file telling the typechecker where to find the sources.
        #
        # See: https://github.com/MercuryTechnologies/buck2-prelude/blob/fa973386098923e85eec5ae1911433749a783bf5/python/typing.bzl#L54-L63
        "type_checker": attrs.dep(providers = [RunInfo], default = "//:pyrefly"),
        "pex_extension": attrs.string(default = ".pex"),
        # I do NOT "get" this `select` stuff.
        "platform": attrs.string(default = select({
            "@prelude//cpu:arm64": "arm64",
            "@prelude//cpu:x86_64": "x86_64",
        })),
    },
    is_toolchain_rule = True,
)
