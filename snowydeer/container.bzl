# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Tools for building Docker images with Buck2 via Nix.
"""

load("@toolchains//nix/nix_build.bzl", "NixDynamicDepsTset", "NixDynamicInfo", "NixPathInfo")
# @moss-disable[end= ]: load("//snowydeer/container:mercury_attrs.bzl", "buck_path_to_url", "extract_mercury_metadata", "mercury_metadata_attrs")

mercury_metadata_attrs = lambda: {}  # @moss-enable
extract_mercury_metadata = lambda attrs: {}  # @moss-enable
buck_path_to_url = lambda label: str(label)  # @moss-enable

_DepKind = enum("nix", "buck2")

# Partitioned dep reference (since we aren't allowed to have heterogeneous
# lists going into dynamic actions).
_Dep = record(kind = _DepKind, index = int)

def _make_build_plan_impl(
        actions: AnalysisActions,
        buck_labels: list[TargetLabel],
        nix_deps: list[ResolvedDynamicValue],
        contents: list[_Dep],
        main_contents: list[_Dep],
        static_part: dict,
        build_plan: OutputArtifact) -> list[Provider]:
    def unpartition(d: _Dep) -> str:
        if d.kind == _DepKind("nix"):
            # FIXME(jadel): unclear semantics for NixDepsTsetProvider, so we don't support it.
            return nix_deps[d.index].providers[NixPathInfo].path
        else:
            return str(buck_labels[d.index])

    contents = [unpartition(d) for d in contents]
    main_contents = [unpartition(d) for d in main_contents]

    actions.write_json(build_plan, {
        "contents": contents,
        "mainContents": main_contents,
    } | static_part, with_inputs = True)

    return []

_make_build_plan = dynamic_actions(
    impl = _make_build_plan_impl,
    attrs = {
        "buck_labels": dynattrs.list(dynattrs.value(TargetLabel)),
        "nix_deps": dynattrs.list(dynattrs.dynamic_value()),
        "contents": dynattrs.list(dynattrs.value(_Dep)),
        "main_contents": dynattrs.list(dynattrs.value(_Dep)),
        # Statically determined part of the build plan.
        "static_part": dynattrs.value(dict),
        "build_plan": dynattrs.output(),
    },
)

_PartitionResult = record(nix_deps = list[DynamicValue], buck_deps = list[TargetLabel], assignments = list[_Dep])

def partition_deps(prev: _PartitionResult | None, deps: list[Dependency]) -> _PartitionResult:
    nix_deps = prev.nix_deps if prev else []
    buck_deps = prev.buck_deps if prev else []
    assignments = []

    def find_append(l: list, item) -> int:
        if item in l:
            idx = l.index(item)
        else:
            l.append(item)
            idx = len(l) - 1
        return idx

    for dep in deps:
        # FIXME(jadel): we shouldn't have two of these, refactor this :(
        if NixDynamicInfo in dep:
            dyn = dep[NixDynamicInfo].dynamic
            idx = find_append(nix_deps, dyn)
            assignments.append(_Dep(kind = _DepKind("nix"), index = idx))
        elif NixDynamicDepsTset in dep:
            fail("FIXME: support NixDynamicDepsTset; not immediately obvious how to handle receiving multiple paths")
        else:
            # Eugh! We actually cannot build any buck2 deps at this point since
            # snowydeer needs to uquery them to find transitive nix deps, so we
            # have to just give the labels over to snowydeer and let it deal
            # with them... I wonder if we can somehow do that query in a rule
            # and stop using BXL in snowydeer.
            #
            # Theoretically string parameter macros are allowed to do queries
            # but I bet rules can't.
            idx = find_append(buck_deps, dep.label.raw_target())
            assignments.append(_Dep(kind = _DepKind("buck2"), index = idx))
    return _PartitionResult(nix_deps = nix_deps, buck_deps = buck_deps, assignments = assignments)

def _container_impl(ctx: AnalysisContext):
    build_plan = ctx.actions.declare_output("build_plan.json")
    static_part = {
        "name": ctx.label.name,
        "cmd": ctx.attrs.cmd,
        "env": ctx.attrs.env,
        "ports": ctx.attrs.ports,
        "metadata": {
            "org.opencontainers.image.description": ctx.attrs.description,
            # "org.opencontainers.image.revision" and "org.opencontainers.image.version" come from Haskell :)
            "org.opencontainers.image.title": str(ctx.label.raw_target()),
            "org.opencontainers.image.source": buck_path_to_url(ctx.label),
        } | extract_mercury_metadata(ctx.attrs),
    }
    contents_result = partition_deps(None, ctx.attrs.contents)
    main_contents_result = partition_deps(contents_result, ctx.attrs.main_contents)

    ctx.actions.dynamic_output_new(_make_build_plan(
        nix_deps = main_contents_result.nix_deps,
        buck_labels = main_contents_result.buck_deps,
        contents = contents_result.assignments,
        main_contents = main_contents_result.assignments,
        static_part = static_part,
        build_plan = build_plan.as_output(),
    ))

    build_container = ctx.attrs._build_container[RunInfo].args
    (written, _) = ctx.actions.write(
        "container_upload.sh",
        cmd_args(
            "#!/usr/bin/env bash",
            "set -euo pipefail",
            cmd_args(
                build_container,
                cmd_args(build_plan, quote = "shell"),
                "\"$@\"",
                delimiter = " ",
            ),
        ),
        is_executable = True,
        with_inputs = True,
        allow_args = True,
    )

    return [DefaultInfo(default_output = written), RunInfo(args = cmd_args(written))]

snowydeer_container = rule(
    impl = _container_impl,
    attrs = {
        "description": attrs.string(doc = "Description of the image"),
        "cmd": attrs.list(attrs.string(), doc = "Description of the image"),
        "env": attrs.dict(attrs.string(), attrs.string(), doc = "Environment to set in the image by default", default = {}),
        "contents": attrs.list(attrs.dep(), default = [], doc = "What to put in the root of the image"),
        "main_contents": attrs.list(attrs.dep(), doc = "What to promote to its own layers in the image"),
        "ports": attrs.list(attrs.string(), default = [], doc = "Ports to expose, e.g. '9000/tcp'"),
        "_build_container": attrs.dep(default = "//snowydeer/container"),
    } | mercury_metadata_attrs(),
)
