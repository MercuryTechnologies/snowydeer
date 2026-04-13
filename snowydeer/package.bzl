# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Packages a target into an output directory with bin/, which can then be
imported into the nix store.
"""

load("@prelude//cfg/modifier:name.bzl", "cfg_name")

def _transition_to_static_impl(ctx: AnalysisContext):
    constraint = ctx.attrs.constraint
    new_value = ctx.attrs.new_value

    def transition_impl_with_refs(platform: PlatformInfo) -> PlatformInfo:
        constraints = platform.configuration.constraints

        # do nothing if someone has set the constraint explicitly, since they
        # probably meant it!
        setting = constraint[ConstraintSettingInfo]
        if setting.label in constraints:
            return platform

        constraints[setting.label] = new_value[ConstraintValueInfo]

        new_cfg = ConfigurationInfo(
            constraints = constraints,
            values = platform.configuration.values,
        )

        return PlatformInfo(
            # This will produce `cfg:<empty>` as a cfg name to match the cfg name of
            # configurations created via modifiers. We might want to improve
            # the name generation for that for clarity via updating that naming
            # function, but that's a later problem.
            #
            # For reference as to how modifier configs get their names:
            # https://github.com/facebook/buck2-prelude/blob/a977197a97f64bc8119d0c25e8c5693832ad74b0/cfg/modifier/name.bzl#L38
            label = cfg_name(new_cfg),
            configuration = new_cfg,
        )

    return [DefaultInfo(), TransitionInfo(impl = transition_impl_with_refs)]

transition_to_static = rule(
    impl = _transition_to_static_impl,
    doc = """
    Transitions a target to be built statically linked rather than with dynamic linking.

    This is necessary for packaging as we don't deal with pulling in dependency
    dylibs in the package rule yet.

    NOTE: This likely causes a bunch of expensive rebuilds as it switches the
    configuration hash of everything! We might be able to make it only relink
    (perhaps by using modifiers more successfully).

    See: https://github.com/facebook/buck2/issues/832
    and more importantly: https://github.com/facebook/buck2/issues/448
    """,
    attrs = {
        "constraint": attrs.default_only(attrs.dep(default = "//constraints/link_style")),
        "new_value": attrs.default_only(attrs.dep(default = "//constraints/link_style:static_pic")),
    },
    is_configuration_rule = True,
)

def _snowydeer_package_impl(ctx: AnalysisContext) -> list[Provider]:
    # we might still have to write this as a thing that calls a python
    # executable at some point if we want to do rpath patching, but until that
    # happens, might as well try just doing it in starlark

    output_dir = ctx.actions.declare_output("out_dir", dir = True)
    binaries = ctx.attrs.extra_files
    for bin in ctx.attrs.binaries:
        chosen_output = bin.get(DefaultInfo).default_outputs[0]
        binaries["bin/{}".format(chosen_output.basename)] = chosen_output

    ctx.actions.copied_dir(output_dir, binaries)

    return [
        DefaultInfo(default_outputs = [output_dir]),
    ]

snowydeer_package = rule(
    impl = _snowydeer_package_impl,
    doc = """
    Packages some targets into a directory such that it can be imported into
    the Nix store.

    Builds the binaries as statically linked.
    """,
    attrs = {
        "binaries": attrs.list(
            attrs.transition_dep(providers = [DefaultInfo], cfg = "//snowydeer:transition_to_static"),
            doc = """
            Binaries to put in the bin/ directory of the resulting package.
            """,
        ),
        "extra_files": attrs.dict(
            attrs.string(doc = "Path to copy to in the output, e.g. share/foo"),
            attrs.source(doc = "File/directory to copy to that path"),
            doc = """
            Extra files to copy into the package.

            N.B. don't put binaries in here lest they not be statically linked!
            """,
            default = {},
        ),
    },
)
