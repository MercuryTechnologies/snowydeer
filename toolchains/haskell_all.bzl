# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
"""
Functionality on "all" Haskell toolchain packages: building them all, uploading
them to Nix cache, and similar features.
"""

load(
    "@buck2-haskell//:toolchain.bzl",
    "DynamicHaskellToolchainPackageDbInfo",
    "HaskellToolchainInfo",
)
load("@toolchains//nix:nix_haskell_toolchain.bzl", "DynamicHaskellNixInfo")
load("@toolchains//nix:nix_upload.bzl", "upload_to_cache")

# FIXME(jadel): this is duplicate logic as in toolchains/nix_build.bzl. Needs to be DRY'd up eventually.
def _record_nix_path_dynamic_impl(actions, arg, pkg_deps, list_of_packages):
    package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages

    cmd = cmd_args(arg.record_nix_path, "--output", list_of_packages)
    ks = package_db.keys()
    for k in ks:
        out_link = package_db[k].value.path
        cmd.add("--input", out_link)

    actions.run(cmd, category = "all_nix_packages")
    return []

_record_nix_path_dynamic = dynamic_actions(
    impl = _record_nix_path_dynamic_impl,
    attrs = {
        "arg": dynattrs.value(typing.Any),
        "pkg_deps": dynattrs.dynamic_value(),
        "list_of_packages": dynattrs.output(),
    },
)

def _upload_haskell_nix_dynamic_impl(actions: AnalysisActions, arg: typing.Any, pkg_deps: ResolvedDynamicValue, summary_upload_status: OutputArtifact) -> list[Provider]:
    package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages
    package_nix = pkg_deps.providers[DynamicHaskellNixInfo].packages

    # FIXME(jadel): this might want to use the dependencies tset somehow in case we
    # want to allow buck targets in here somehow, but we aren't doing that
    # right now.
    input_args = cmd_args()
    for name, nix_der_info in package_nix.items():
        nix_path = {}
        nix_path["drv"] = nix_der_info.package.derivation.path
        for k in ["out", "hie", "doc"]:
            if k in nix_der_info.package.outputs:
                nix_path[k] = nix_der_info.package.outputs[k].path

        str = ""
        for k in ["drv", "out", "hie", "doc"]:
            if k in nix_path:
                # print("uploading {}".format(nix_path[k]))
                str += "{}\n".format(nix_path[k])

        batch_items = actions.declare_output("{}_input.txt".format(name))
        actions.write(batch_items, str.strip())
        out_link = package_db[name].value.path
        each_upload_status = upload_to_cache(
            actions = actions,
            cache_hook = arg.cache_hook,
            update_cache = arg.update_cache,
            batch_name = name,
            batch_items = batch_items,
            deps = [out_link],
        )
        input_args.add("--input", each_upload_status)

    summarize_args = [cmd_args(arg.summarize_upload_status)]
    summarize_args.append(input_args)

    cmd = cmd_args(summarize_args, "--output", summary_upload_status)
    actions.run(cmd, category = "update_nix_cache_summary")

    return []

_upload_haskell_nix_dynamic = dynamic_actions(
    impl = _upload_haskell_nix_dynamic_impl,
    attrs = {
        "arg": dynattrs.value(typing.Any),
        "pkg_deps": dynattrs.dynamic_value(),
        "summary_upload_status": dynattrs.output(),
    },
)

def _mercury_haskell_toolchain_all_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_toolchain = ctx.attrs.toolchain[HaskellToolchainInfo]
    list_of_packages = ctx.actions.declare_output("all_haskell_nix_paths.txt")
    summary_upload_status = ctx.actions.declare_output("summary_upload_status.txt")

    ctx.actions.dynamic_output_new(_record_nix_path_dynamic(
        arg = struct(
            record_nix_path = ctx.attrs._record_nix_path[RunInfo],
        ),
        pkg_deps = haskell_toolchain.packages.dynamic,
        list_of_packages = list_of_packages.as_output(),
    ))

    ctx.actions.dynamic_output_new(_upload_haskell_nix_dynamic(
        arg = struct(
            cache_hook = ctx.attrs._cache_hook[RunInfo],
            update_cache = ctx.attrs._update_cache[RunInfo],
            summarize_upload_status = ctx.attrs._summarize_upload_status[RunInfo],
        ),
        pkg_deps = haskell_toolchain.packages.dynamic,
        summary_upload_status = summary_upload_status.as_output(),
    ))

    sub_targets = {}
    sub_targets["upload"] = [DefaultInfo(default_outputs = [summary_upload_status])]

    return [
        DefaultInfo(
            default_outputs = [list_of_packages],
            sub_targets = sub_targets,
        ),
    ]

mercury_haskell_toolchain_all = rule(
    impl = _mercury_haskell_toolchain_all_impl,
    attrs = {
        "_cache_hook": attrs.dep(
            providers = [RunInfo],
            default = "toolchains//:cache-hook",
        ),
        "_record_nix_path": attrs.dep(
            providers = [RunInfo],
            default = "toolchains//tools:record_nix_path",
        ),
        "_update_cache": attrs.dep(
            providers = [RunInfo],
            default = "toolchains//tools:update_cache",
        ),
        "_summarize_upload_status": attrs.dep(
            providers = [RunInfo],
            default = "toolchains//tools:summarize_upload_status",
        ),
        "toolchain": attrs.toolchain_dep(
            providers = [HaskellToolchainInfo],
        ),
        "allow_cache_upload": attrs.bool(default = True),
    },
)
