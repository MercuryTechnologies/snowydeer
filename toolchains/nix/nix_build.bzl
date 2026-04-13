# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Run a `nix build` command for a given `flake` and `attr` to build.
"""

def _nix_build_impl(ctx: AnalysisContext):
    """
    calls nix build path:<flake-path>#<attr>
    """
    flake = ctx.attrs.flake
    attr = ctx.attrs.attr or ctx.label.name
    binary = ctx.attrs.binary
    binaries = ctx.attrs.binaries

    attr_suffix = attr
    out_name = "out.link"
    if ctx.attrs.suffix:
        attr_suffix = cmd_args(attr, ctx.attrs.suffix, delimiter = "^")
        if ctx.attrs.suffix != "out":
            # Even if `out` isn't the default output _and_ it's specified
            # explicitly, Nix will write `out.link` (not `out.link-out`) for
            # the output named `out`.
            out_name = "out.link-{}".format(ctx.attrs.suffix)
    out_link = ctx.actions.declare_output(out_name)

    # When we pass an `--out-link out.link` to Nix, it adds suffixes (e.g.
    # `out.link-man`) based on the names of the outputs of the built
    # derivation.
    #
    # Therefore, we always need to pass a path to a plain `out.link`, even if
    # the default output we want to return includes a suffix for a specific
    # non-default named output.
    #
    # NB: If you do (e.g.) `nix build --out-link out.link nixpkgs#libheif.man`,
    # Nix will write (perhaps unintuitively) an `out.link-man` link, even
    # though you're building a single output.
    out_link_for_nix = cmd_args(
        out_link.as_output(),
        parent = 1,
        absolute_suffix = "/out.link",
        hidden = [out_link.as_output()],
    )

    nix_build = cmd_args([
        "env",
        "--",  # this is needed to avoid "Spawning executable `nix` failed: Failed to spawn a process"
        "nix",
        "build",
        "--print-build-logs",
        "--show-trace",
        # --no-update-lock-file: if the flake.lock file does not match the flake.nix, error out.
        # This prevents highly baffling behaviour that should be done by the user rather than by buck2.
        "--no-update-lock-file",
        # Don't use flake registries if someone omits something from `inputs.*` but puts it in `outputs` args.
        "--no-use-registries",
        cmd_args("--out-link", out_link_for_nix),
        cmd_args(cmd_args(flake, attr_suffix, delimiter = "#"), absolute_prefix = "path:"),
    ])
    ctx.actions.run(nix_build, category = "nix_build", local_only = True)

    run_info = []
    if binary:
        run_info.append(
            RunInfo(
                args = cmd_args(out_link, "bin", ctx.attrs.binary, delimiter = "/"),
            ),
        )

    nix_dynamic_info = NixDynamicInfo(
        dynamic = _read_out_link(ctx, out_link),
    )

    sub_targets = {
        bin: [DefaultInfo(default_output = out_link), RunInfo(args = cmd_args(out_link, "bin", bin, delimiter = "/"))]
        for bin in binaries
    }

    return [
        DefaultInfo(
            default_output = out_link,
            sub_targets = sub_targets,
        ),
        # Note: This is just a path to the `bin` directory, it doesn't actually
        # have to exist!
        BinDirInfo(
            args = cmd_args(out_link, "bin", delimiter = "/"),
        ),
        # absolute nix path information will be recorded here. It is a dynamic value.
        nix_dynamic_info,
    ] + run_info

nix_build = rule(
    impl = _nix_build_impl,
    doc = """
        Run a `nix build` command for a given `flake` and `attr` to build.
    """,
    attrs = {
        "binary": attrs.option(attrs.string(), default = None),
        "binaries": attrs.list(attrs.string(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        "flake": attrs.source(allow_directory = True),
        "attr": attrs.option(attrs.string(), doc = "name of the flake attribute, defaults to label name", default = None),
        "suffix": attrs.option(attrs.string(), default = None, doc = "out-link suffix, e.g. `lib`, used to provide a non-default output"),
    },
)

def _read_out_link_dynamic_impl(
        # starlark-lint-disable unused-argument
        actions: AnalysisActions,  # @unused
        read_link):
    nix_path = read_link.read_string()
    return [NixPathInfo(path = nix_path)]

_read_out_link_dynamic = dynamic_actions(
    impl = _read_out_link_dynamic_impl,
    attrs = {
        "read_link": dynattrs.artifact_value(),
    },
)

# FIXME(jadel): this is duplicate logic as in haskell/mercury_haskell.bzl. Needs to be DRY'd up eventually.
def _read_out_link(ctx: AnalysisContext, out_link: Artifact) -> DynamicValue:
    read_link = ctx.actions.declare_output("read_link")
    ctx.actions.run(
        cmd_args("bash", "-ec", """readlink $1 | tr -d '\\n' > $2""", "--", out_link, read_link.as_output()),
        category = "nix_path",
        local_only = True,
    )

    dyn_nix_path = ctx.actions.dynamic_output_new(_read_out_link_dynamic(
        read_link = read_link,
    ))

    return dyn_nix_path

BinDirInfo = provider(
    doc = """Provides the path of the `/bin` directory of a derivation output.""",
    fields = {
        "args": provider_field(cmd_args),
    },
)

# FIXME(jadel): Unify with a dynamic for `NixDynamicDepsTset`.
NixDynamicInfo = provider(
    doc = """Provides nix-side dynamic information. Contains a NixPathInfo provider.""",
    fields = {
        "dynamic": DynamicValue,
    },
)

NixDynamicDepsTset = provider(
    doc = """Provides nix-side dynamic information. Contains a NixDepsTsetProvider provider.""",
    fields = {
        "dynamic": DynamicValue,
    },
)

NixPathInfo = provider(
    doc = """Provides the absolute /nix/store path.""",
    fields = {
        "path": str,
    },
)

# All of the output paths for a derivation.
NixDerivationInfo = record(
    derivation = NixPathInfo,
    outputs = dict[str, NixPathInfo],
)

def _project_path(path: NixDerivationInfo) -> list[str]:
    return [out.path for out in path.outputs.values()]

# All Nix output paths referenced by this target including transitively.
# Contains elements of type NixDerivationInfo.
# Does not keep track of outputs separately (FIXME?) and we just ref-scan for *all* output paths and prune afterwards.
NixDepsTset = transitive_set(json_projections = {"all_output_paths": _project_path})

NixDepsTsetProvider = provider(
    doc = """Provides a NixDepsTset.""",
    fields = {
        "deps": NixDepsTset,
    },
)

# One Nix package, effectively; with *buck2-level* Nix dependency info.
# The dependencies are not a comprehensive list of all of the dependencies at a
# Nix level and these will likely mirror the Nix level dependency structure to
# a degree.
# The Nix-level transitive closure of NixDepsTset here should include all possible Nix
# deps of the final target.
#
# The dependencies should include the package itself; this is only a packaging
# of the two parts together for convenience.
NixDependency = record(
    package = NixDerivationInfo,
    deps = NixDepsTset,
)
