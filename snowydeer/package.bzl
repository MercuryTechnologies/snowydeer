# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Packages a target into an output directory with bin/, which can then be
imported into the nix store.
"""

load("@prelude//cfg/modifier:name.bzl", "cfg_name")
load("//snowydeer:snowydeer_import.bzl", "snowydeer_import")

def _transition_impl(ctx: AnalysisContext):
    automatic_value = ctx.attrs.automatic_value[ConstraintValueInfo]
    new_value = ctx.attrs.new_value

    def transition_impl_with_refs(platform: PlatformInfo) -> PlatformInfo:
        configuration = platform.configuration.copy()

        # Preserve an explicitly selected link style, but resolve automatic
        # linking to the static style required for packaging.
        if configuration.get(automatic_value.setting) != automatic_value:
            return platform

        configuration.insert(new_value[ConstraintValueInfo])

        return PlatformInfo(
            # This will produce `cfg:<empty>` as a cfg name to match the cfg name of
            # configurations created via modifiers. We might want to improve
            # the name generation for that for clarity via updating that naming
            # function, but that's a later problem.
            #
            # For reference as to how modifier configs get their names:
            # https://github.com/facebook/buck2-prelude/blob/a977197a97f64bc8119d0c25e8c5693832ad74b0/cfg/modifier/name.bzl#L38
            label = cfg_name(configuration),
            configuration = configuration,
        )

    return [DefaultInfo(), TransitionInfo(impl = transition_impl_with_refs)]

transition = rule(
    impl = _transition_impl,
    doc = """
    Transitions a target from a default to a non-default configuration,
    skipping the transition if the configuration is explicitly specified.

    We use this for transitioning to a static configuration while building packages.
    Static builds are necessary for packaging as we don't deal with pulling in
    dependency dylibs in the package rule yet.

    NOTE: This likely causes a bunch of expensive rebuilds as it switches the
    configuration hash of everything! We might be able to make it only relink
    (perhaps by using modifiers more successfully).

    See: https://github.com/facebook/buck2/issues/832
    and more importantly: https://github.com/facebook/buck2/issues/448
    """,
    attrs = {
        "automatic_value": attrs.dep(),
        "new_value": attrs.dep(),
    },
    is_configuration_rule = True,
)

def _snowydeer_package_artifact_impl(ctx: AnalysisContext) -> list[Provider]:
    # we might still have to write this as a thing that calls a python
    # executable at some point if we want to do rpath patching (or patching
    # interpreters of python stuff so we can ship python to prod), but until
    # that happens, might as well try just doing it in starlark

    output_dir = ctx.actions.declare_output("out_dir", dir = True)
    binaries = ctx.attrs.extra_files
    for bin in ctx.attrs.binaries:
        chosen_output = bin.get(DefaultInfo).default_outputs[0]
        binaries["bin/{}".format(chosen_output.basename)] = chosen_output

    ctx.actions.copied_dir(output_dir, binaries)

    return [
        DefaultInfo(default_outputs = [output_dir]),
    ]

_snowydeer_package_artifact = rule(
    impl = _snowydeer_package_artifact_impl,
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

def snowydeer_package(
        name: str,
        binaries,
        extra_files = {},
        target_compatible_with = [],
        exec_compatible_with = [],
        compatible_with = [],
        default_target_platform = None,
        **kwargs):
    # This uses two separate targets since `attrs.query()` cannot transition
    # configurations itself.
    # Thus, you need a second target which is *already* in the intended
    # configuration to match the configurations of the query and the
    # `attrs.dep()`. In other words, we cannot use a `attrs.transition_dep()`
    # in the same rule as the `attrs.query()` and get the same configuration
    # between the two.
    artifact_name = name + "__snowydeer_artifact"
    _snowydeer_package_artifact(
        name = artifact_name,
        binaries = binaries,
        compatible_with = compatible_with,
        default_target_platform = default_target_platform,
        exec_compatible_with = exec_compatible_with,
        extra_files = extra_files,
        target_compatible_with = target_compatible_with,
        visibility = [":{}".format(name)],
    )

    snowydeer_import(
        name = name,
        artifact = ":{}".format(artifact_name),
        compatible_with = compatible_with,
        default_target_platform = default_target_platform,
        exec_compatible_with = exec_compatible_with,
        nix_deps = "deps(:{})".format(artifact_name),
        target_compatible_with = target_compatible_with,
        **kwargs
    )
