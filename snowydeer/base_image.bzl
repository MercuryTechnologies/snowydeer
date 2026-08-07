# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Pinned third-party base images for Snowydeer Container.

A `snowydeer_base_image` target carries a pinned reference to a prebuilt OCI
image. It supports multiple architectures: just pass multiple entries in
`nar_hashes`.
A `snowydeer_container` can build on top of it using its `base_image` argument.

The base image is not a buck artifact itself, but merely data passed into Nix.
You can build it with `buck build` to verify it is buildable in isolation
though! See `docs/buck2/deployment/containers.md`.

- `buck build //…:base`          -> validates the pinned image can be pulled
- `buck run  //…:base -- update` -> re-pins to `follows_tag` via nix-prefetch-docker
- `buck run  //…:base -- lock`   -> fixes `nar_hashes` for an existing `digest`
"""

# Provider consumed by `snowydeer_container`. The pin is already resolved to the
# active architecture (see `_system`); os/arch are derived from `system`
# (the Nix system double, e.g. "x86_64-linux") on the Nix side.
SnowydeerBaseImageInfo = provider(fields = {
    "image_name": str,
    "system": str,
    "digest": str,
    "nar_hash": str,
})

# Maps a configured CPU to the Nix system double that keys the nar_hashes table.
_SYSTEM_SELECT = select({
    "@prelude//cpu:arm64": "aarch64-linux",
    "@prelude//cpu:x86_64": "x86_64-linux",
})

def _base_image_impl(ctx: AnalysisContext) -> list[Provider]:
    system = ctx.attrs._system
    digest = ctx.attrs.digest
    nar_hash = ctx.attrs.nar_hashes.get(system) or ""

    # If any arch already has a nar_hash the table has been partially populated;
    # a missing entry for the current system is then a mistake.
    any_pinned = False
    for v in ctx.attrs.nar_hashes.values():
        if v:
            any_pinned = True
            break
    if any_pinned and (not digest or not nar_hash):
        fail("snowydeer_base_image {tgt}: no pin for system '{sys}'. Add it to `nar_hashes` and run `buck run {tgt} -- update`.".format(
            tgt = ctx.label.raw_target(),
            sys = system,
        ))

    spec = ctx.actions.write_json(
        "base_image_spec.json",
        {
            "imageName": ctx.attrs.image_name,
            "followsTag": ctx.attrs.follows_tag,
            # this deliberately eats the cell name because buildozer doesn't
            # know what it is
            "label": "//" + ctx.label.package + ":" + ctx.label.name,
            "activeSystem": system,
            "imageDigest": digest,
            "narHashes": {
                s: ctx.attrs.nar_hashes.get(s) or ""
                for s in ctx.attrs.nar_hashes.keys()
            },
        },
    )

    container = ctx.attrs._build_container[RunInfo]

    # `buck run //…:base`
    run_info = RunInfo(args = cmd_args(container, "base-image", spec))

    if not digest or not nar_hash:
        # Not yet pinned; `buck build` is a no-op, `buck run -- update` works.
        return [DefaultInfo(), run_info]

    info = SnowydeerBaseImageInfo(
        image_name = ctx.attrs.image_name,
        system = system,
        digest = digest,
        nar_hash = nar_hash,
    )

    # `buck build` -> pull-validate the pinned arch (opt-in: containers read the
    # provider's string fields, which does not force this output).
    validated = ctx.actions.declare_output("validated.txt")
    ctx.actions.run(
        cmd_args(container, "base-image", spec, "validate", "--out", validated.as_output()),
        category = "snowydeer_base_image_validate",
        # Network + nix, like nix_build.
        local_only = True,
        allow_cache_upload = False,
    )

    return [
        DefaultInfo(default_output = validated),
        info,
        run_info,
    ]

snowydeer_base_image = rule(
    impl = _base_image_impl,
    attrs = {
        "image_name": attrs.string(doc = "Registry path of the base image, e.g. 'alpine:3.23'."),
        "follows_tag": attrs.option(
            attrs.string(),
            default = None,
            doc = "Tag to follow. This will be followed while updating hashes with `buck run :foo -- update`",
        ),
        "digest": attrs.string(
            default = "",
            doc = "OCI manifest-list digest ('sha256:…'). One value for all arches. Tool-managed by `buck run :foo -- update`.",
        ),
        "nar_hashes": attrs.dict(
            attrs.string(),
            attrs.string(),
            default = {},
            doc = "Per-arch nar hash ('sha256-…') keyed by Nix system double. Tool-managed by `buck run :foo -- update|lock`; don't hand-edit.",
        ),
        # Resolves to the build host's Nix system double; indexes nar_hashes.
        "_system": attrs.string(default = _SYSTEM_SELECT),
        "_build_container": attrs.dep(default = "//snowydeer/container", providers = [RunInfo]),
    },
    doc = "A pinned third-party base image to build a snowydeer_container on top of.",
)
