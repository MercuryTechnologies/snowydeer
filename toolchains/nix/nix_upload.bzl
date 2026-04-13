# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Uploads Nix store paths to the cache.
"""

load(":nix_build.bzl", "NixDynamicInfo", "NixPathInfo")

# Upload the Nix packages to designated Nix cache.
# Script is provided by pkgs.mercury.cache-hook.
def upload_to_cache(
        actions,
        # cache_hook script (currently, nix/packages/mercury/cache-hook.nix)
        cache_hook: RunInfo,
        # update_cache script (a simple wrapper of cache_hook to produce output artifact)
        update_cache: RunInfo,
        # name of this batch
        batch_name,
        # the list of nix package paths for this batch to upload
        batch_items: Artifact,
        # hidden dependencies (out_link)
        deps: list[Artifact]) -> Artifact:
    upload_status = actions.declare_output("{}_upload_status.log".format(batch_name))
    cmd = cmd_args(update_cache, hidden = deps)
    cmd.add("--hook", cache_hook)
    cmd.add("--input", batch_items)
    cmd.add("--output", upload_status.as_output())
    actions.run(cmd, category = "update_nix_cache", identifier = batch_name)
    return upload_status

# FIXME(jadel): some duplicate logic in toolchain/nix_build.bzl; should all be
# unified onto NixDynamicDepsTset or similar.
def _dump_nix_paths_dynamic_impl(
        actions,
        list_of_packages: OutputArtifact,
        dyn_nix_paths: list[ResolvedDynamicValue]) -> list[Provider]:
    nix_paths = [dyn_nix_path.providers[NixPathInfo].path for dyn_nix_path in dyn_nix_paths]
    str = "\n".join(nix_paths).strip()
    actions.write(list_of_packages, "{}".format(str))
    return []

_dump_nix_paths_dynamic = dynamic_actions(
    impl = _dump_nix_paths_dynamic_impl,
    attrs = {
        "list_of_packages": dynattrs.output(),
        "dyn_nix_paths": dynattrs.list(dynattrs.dynamic_value()),
    },
)

def _flake_nix_paths_impl(ctx: AnalysisContext) -> list[Provider]:
    dyn_nix_paths = [flake[NixDynamicInfo].dynamic for flake in ctx.attrs.flakes]
    list_of_packages = ctx.actions.declare_output("all_flake_nix_paths.txt")

    ctx.actions.dynamic_output_new(_dump_nix_paths_dynamic(
        dyn_nix_paths = dyn_nix_paths,
        list_of_packages = list_of_packages.as_output(),
    ))

    upload_status = upload_to_cache(
        actions = ctx.actions,
        cache_hook = ctx.attrs._cache_hook[RunInfo],
        update_cache = ctx.attrs._update_cache[RunInfo],
        batch_name = "flakes",
        batch_items = list_of_packages,
        deps = [],
    )
    sub_targets = {}
    sub_targets["upload"] = [DefaultInfo(default_outputs = [upload_status])]

    return [
        DefaultInfo(
            default_outputs = [list_of_packages],
            sub_targets = sub_targets,
        ),
    ]

flake_nix_paths = rule(
    impl = _flake_nix_paths_impl,
    attrs = {
        "flakes": attrs.list(attrs.dep(providers = [NixDynamicInfo]), default = []),
        "_cache_hook": attrs.dep(
            providers = [RunInfo],
            default = "toolchains//:cache-hook",
        ),
        "_update_cache": attrs.dep(
            providers = [RunInfo],
            default = "toolchains//tools:update_cache",
        ),
    },
)
