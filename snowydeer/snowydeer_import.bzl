# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Imports Buck2 artifacts into the Nix store.
"""

load("@toolchains//nix/nix_build.bzl", "NixDepsTsetProvider", "NixDynamicDepsTset", "NixPathInfo", "collect_all_nix_output_dynamics_for_target", "nix_dynamic_info_from_path_file")

def collect_nix_dynamics(deps) -> list[DynamicValue]:
    dynamics = []
    for providers in deps:
        dynamics.extend(collect_all_nix_output_dynamics_for_target(providers))
        if NixDynamicDepsTset in providers:
            dynamics.append(providers[NixDynamicDepsTset].dynamic)
    return dynamics

def dump_nix_paths_dynamic_impl(
        actions,
        list_of_packages: OutputArtifact,
        dyn_nix_paths: list[ResolvedDynamicValue]) -> list[Provider]:
    paths = []
    all_tsets = []
    for item in dyn_nix_paths:
        providers = item.providers
        if NixDepsTsetProvider in providers:
            all_tsets.append(providers[NixDepsTsetProvider].deps)
        if NixPathInfo in providers:
            paths.append(providers[NixPathInfo].path)

    # Can't merge these tsets because of https://github.com/facebook/buck2/issues/683.
    # build_store_path deduplicates the resulting paths.
    actions.write_json(list_of_packages, {
        "paths_old": paths,
        "paths_new": [tset.project_as_json("all_output_paths") for tset in all_tsets],
    })

    return []

def _dump_nix_paths_dynamic_impl(
        actions: AnalysisActions,
        list_of_packages: OutputArtifact,
        dyn_nix_paths: list[ResolvedDynamicValue]) -> list[Provider]:
    return dump_nix_paths_dynamic_impl(actions, list_of_packages, dyn_nix_paths)

_dump_nix_paths_dynamic = dynamic_actions(
    impl = _dump_nix_paths_dynamic_impl,
    attrs = {
        "list_of_packages": dynattrs.output(),
        "dyn_nix_paths": dynattrs.list(dynattrs.dynamic_value()),
    },
)

def declare_snowydeer_import(
        actions,
        artifact: Artifact,
        build_store_path,
        nix_dynamics: list[DynamicValue],
        name: str,
        identifier: str,
        dump_nix_paths_dynamic = _dump_nix_paths_dynamic,
        output_suffix: str | None = None) -> Artifact:
    suffix = "_{}".format(output_suffix) if output_suffix else ""
    list_of_paths = actions.declare_output("all_nix_paths{}.json".format(suffix))
    actions.dynamic_output_new(dump_nix_paths_dynamic(
        dyn_nix_paths = nix_dynamics,
        list_of_packages = list_of_paths.as_output(),
    ))

    store_path = actions.declare_output("store_path{}".format(suffix))
    actions.run(
        cmd_args(
            build_store_path,
            "--artifact",
            artifact,
            "--paths-json",
            list_of_paths,
            "--name",
            name,
            "--write-path-to",
            store_path.as_output(),
        ),
        category = "snowydeer_import",
        identifier = identifier,
        local_only = True,
        # The imported store path must be created on the machine that consumes it.
        allow_cache_upload = False,
    )

    return store_path

def _snowydeer_import_impl(ctx: AnalysisContext) -> list[Provider]:
    artifact_info = ctx.attrs.artifact[DefaultInfo]
    if len(artifact_info.default_outputs) != 1:
        fail("snowydeer_import requires exactly one default output")

    store_path = declare_snowydeer_import(
        actions = ctx.actions,
        artifact = artifact_info.default_outputs[0],
        build_store_path = ctx.attrs._build_store_path[RunInfo].args,
        identifier = str(ctx.label),
        name = ctx.label.name,
        nix_dynamics = collect_nix_dynamics(ctx.attrs.nix_deps),
    )
    nix_dynamic_info = nix_dynamic_info_from_path_file(ctx.actions, store_path)

    sub_targets = dict(artifact_info.sub_targets)
    if "store_path" in sub_targets:
        fail("The imported target already has a [store_path] subtarget")
    sub_targets["store_path"] = [
        DefaultInfo(default_output = store_path),
        nix_dynamic_info,
    ]

    return [
        DefaultInfo(
            default_outputs = artifact_info.default_outputs,
            sub_targets = sub_targets,
        ),
        nix_dynamic_info,
    ]

snowydeer_import = rule(
    doc = """
    Imports a buck2 artifact into the Nix store.

    This is a separate target from bundling things into an artifact, since
    `attrs.query()` cannot transition configurations itself; the targets need
    to *already* be in the right configuration before they're queried.
    And, of course, we need the configuration of the query to match
    `artifact`'s configuration.

    This is not public API: please don't use this rule directly outside snowydeer.
    """,
    impl = _snowydeer_import_impl,
    attrs = {
        "artifact": attrs.dep(providers = [DefaultInfo]),
        "nix_deps": attrs.query(doc = "deps() query covering the artifact's complete transitive dependency graph"),
        "_build_store_path": attrs.exec_dep(default = "//snowydeer:build_store_path", providers = [RunInfo]),
    },
)
