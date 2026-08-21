# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Tools for building Docker images with Buck2 via Nix.
"""

load("@toolchains//nix/nix_build.bzl", "NixDynamicInfo", "NixPathInfo")
load("//snowydeer:base_image.bzl", "SnowydeerBaseImageInfo")
# @moss-disable[end= ]: load("//snowydeer/container:mercury_attrs.bzl", "buck_path_to_url", "extract_mercury_metadata", "mercury_metadata_attrs")

mercury_metadata_attrs = lambda: {}  # @moss-enable
extract_mercury_metadata = lambda attrs: {}  # @moss-enable
buck_path_to_url = lambda label: str(label)  # @moss-enable

def _make_build_plan_impl(
        actions: AnalysisActions,
        contents: list[ResolvedDynamicValue],
        main_contents: list[ResolvedDynamicValue],
        static_part: dict,
        build_plan: OutputArtifact) -> list[Provider]:
    def store_paths(deps: list[ResolvedDynamicValue]) -> list[str]:
        # FIXME(jadel): unclear semantics for NixDepsTsetProvider, so we don't support it.
        return [dep.providers[NixPathInfo].path for dep in deps]

    actions.write_json(build_plan, {
        "contents": store_paths(contents),
        "mainContents": store_paths(main_contents),
    } | static_part, with_inputs = True)

    return []

_make_build_plan = dynamic_actions(
    impl = _make_build_plan_impl,
    attrs = {
        "contents": dynattrs.list(dynattrs.dynamic_value()),
        "main_contents": dynattrs.list(dynattrs.dynamic_value()),
        # Statically determined part of the build plan.
        "static_part": dynattrs.value(dict),
        "build_plan": dynattrs.output(),
    },
)

def _nix_dynamics(deps: list[Dependency]) -> list[DynamicValue]:
    return [dep[NixDynamicInfo].dynamic for dep in deps]

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

    # Optional third-party base image. The target machine's nar hash passes
    # straight through to the build plan; the Nix builder turns it into
    # `streamLayeredImage`'s `fromImage`.
    if ctx.attrs.base_image != None:
        base = ctx.attrs.base_image[SnowydeerBaseImageInfo]
        static_part["baseImage"] = {
            "imageName": base.image_name,
            "system": base.system,
            "imageDigest": base.digest,
            "hash": base.nar_hash,
        }

    ctx.actions.dynamic_output_new(_make_build_plan(
        contents = _nix_dynamics(ctx.attrs.contents),
        main_contents = _nix_dynamics(ctx.attrs.main_contents),
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
                "builder",
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
        # Contents must already know their own Nix store path: either a
        # `snowydeer_package` or a `nix_build`.
        "contents": attrs.list(attrs.dep(providers = [NixDynamicInfo]), default = [], doc = "What to put in the root of the image"),
        "main_contents": attrs.list(attrs.dep(providers = [NixDynamicInfo]), doc = "What to promote to its own layers in the image"),
        "ports": attrs.list(attrs.string(), default = [], doc = "Ports to expose, e.g. '9000/tcp'"),
        "base_image": attrs.option(attrs.dep(providers = [SnowydeerBaseImageInfo]), default = None, doc = "Optional pinned third-party base image to build on top of"),
        # FIXME(DUX-5633): transitioning to exec dep causes stochastic CI
        # failure due to persistent worker bugs on different configurations.
        "_build_container": attrs.dep(default = "//snowydeer/container"),
    } | mercury_metadata_attrs(),
)
