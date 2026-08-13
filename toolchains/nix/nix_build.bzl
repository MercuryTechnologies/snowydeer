# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Run a `nix build` command for a given `flake` and `attr` to build.
"""

# Note [Redesigning Nix input-side integration]:
# This code is known to be kind of slow! There's a couple of reasons for it:
# 1. It evaluates all the common parts of nixpkgs for each and every
#    `nix_build` we run. The startup time of nixpkgs evaluation isn't amortized
#    across multiple demanded derivations.
# 2. It makes a new daemon connection for each realisation (build/substitute of
#    a derivation's outputs) which invokes process startup/etc of a nix daemon
#    process, as well as adding extra latency by having a parallel copy of the
#    derivation-level dependency graph in buck2 alongside the one in nix.
#
# Currently the Haskell set solves (1) by ./tools/nix_drv_json.py, which
# evaluates all the Haskell packages in one big (non-concurrent) action.
# Then it builds them one by one in post-order.
#
# Probably the future direction of this is something to the effect of:
# 1. One big nix-eval-jobs action gives us all the drv paths and output paths.
#
#    Dep structure: nix_eval_jobs_all <- extract_drv <- nix_realise <- user
#
#    An extract_drv action prior to realisation extracts the appropriate store
#    path from the big action by itself, to enable early cutoff of realisation
#    actions if that store path didn't change.
#
#    Either that or we do something horrible to nix repl (with
#    `repl-automation`) to turn it into a persistent worker (assuming the
#    underlying fs doesn't change, which it can't really tolerate without
#    restarting?).
# 2. We have some way to let buck2 send us all the demanded realisations in a
#    batch (is that even .. possible?) so that nix can run the build graph
#    itself as efficiently as possible and avoid the latency penalty of nix
#    having to reload the build graph for every separate derivation.
#
#    Nix *also* isn't super efficient at handling path locks itself (I think it
#    might poll them so doesn't immediately resume once a lock is
#    relinquished?), which is another thing that leads to wanting to have an
#    orchestrator for the nix builds that just sees them all.
#
#    Nix *also* doesn't allow multiple concurrent RPCs which means that you
#    probably ideally want it to send it a batch RPC all at once to build all
#    the things *or* have a connection pool to at least avoid nix-daemon-side
#    connection setup costs.

def _nix_realise_worker_impl(ctx: AnalysisContext) -> list[Provider]:
    exe = ctx.attrs.exe[RunInfo].args
    return [
        DefaultInfo(),
        WorkerInfo(exe = exe),
        RunInfo(args = exe),
    ]

nix_realise_worker = rule(
    impl = _nix_realise_worker_impl,
    attrs = {
        "exe": attrs.dep(providers = [RunInfo]),
    },
)

def _out_link_name(output: str) -> str:
    if output == "out":
        # Even if `out` isn't the default output _and_ it's specified
        # explicitly, Nix will write `out.link` (not `out.link-out`) for
        # the output named `out`.
        return "out.link"
    return "out.link-{}".format(output)

def _nix_build_impl(ctx: AnalysisContext):
    """
    calls nix build path:<flake-path>#<attr>
    """

    # See Note [Redesigning Nix input-side integration].
    flake = ctx.attrs.flake
    attr = ctx.attrs.attr or ctx.label.name
    binary = ctx.attrs.binary
    binaries = ctx.attrs.binaries
    outputs = ctx.attrs.outputs

    if len(outputs) != len({output: None for output in outputs}):
        fail("`outputs` has duplicate entries: {}".format(outputs))
    for output in outputs:
        if output in binaries:
            # Both end up as sub-targets of this target, so one would silently
            # shadow the other.
            fail("`{}` is both an output and a binary; they share a sub-target namespace.".format(output))

    # Which Nix output the default output of this target refers to, if we're
    # asking Nix for anything other than the derivation's default outputs.
    primary_output = outputs[0] if outputs else None

    attr_suffix = attr
    if outputs:
        # Nix selects the outputs of one derivation with `attr^out,dev`.
        attr_suffix = cmd_args(attr, cmd_args(outputs, delimiter = ","), delimiter = "^")

    out_name = "out.link" if primary_output == None else _out_link_name(primary_output)
    out_link = ctx.actions.declare_output(out_name)

    # The default output (`out`) goes into both an `[out]` subtarget and the
    # normal target, reusing the same declared output.
    output_links = {
        output: out_link if _out_link_name(output) == out_name else ctx.actions.declare_output(_out_link_name(output))
        for output in outputs
    }
    extra_out_links = [link for output, link in output_links.items() if _out_link_name(output) != out_name]

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
        hidden = [out_link.as_output()] + [link.as_output() for link in extra_out_links],
    )

    # Adding the flake to the store before evaluating lets the eval cache apply
    # to this action. Since buck2 re-materializes the flake artifact after every
    # daemon restart, nix using that directly would mean a fresh mtime each time
    # and no eval cache. In the store, only the content matters as mtime is fixed.
    #
    # `--no-update-lock-file`: require flake.lock to match flake.nix
    # `--no-use-registries`: don't use flake registries if someone omits something
    # from `inputs.*` but puts it in `outputs` args.
    nix_build = cmd_args(
        "bash",
        "-ec",
        """
        flake=$(nix store add-path --name source "$1")
        exec nix build --print-build-logs --show-trace \
            --no-update-lock-file --no-use-registries \
            --out-link "$2" "path:$flake#$3"
        """,
        "--",
        flake,
        out_link_for_nix,
        attr_suffix,
    )
    ctx.actions.run(
        nix_build,
        category = "nix_build",
        local_only = True,
        # Do not allow cache upload on these. It's imperative that nix builds are
        # always run locally so that the store paths are made to exist.
        allow_cache_upload = False,
    )

    run_info = []
    if binary:
        run_info.append(
            RunInfo(
                args = cmd_args(out_link, "bin", ctx.attrs.binary, delimiter = "/"),
            ),
        )

    nix_dynamic_infos = {
        output: _read_out_link(ctx, link, output)
        for output, link in output_links.items()
    }

    if primary_output != None and primary_output in nix_dynamic_infos:
        nix_dynamic_info = nix_dynamic_infos[primary_output]
    else:
        nix_dynamic_info = _read_out_link(ctx, out_link, None)

    sub_targets = {
        bin: [DefaultInfo(default_output = out_link), RunInfo(args = cmd_args(out_link, "bin", bin, delimiter = "/"))]
        for bin in binaries
    }

    # Derivation outputs share a subtarget namespace with `binaries` (fine in
    # practice because who calls a binary `dev`?).
    for output, link in output_links.items():
        sub_targets[output] = [DefaultInfo(default_output = link), nix_dynamic_infos[output]]

    # NOTE: we can't return NixDerivationInfo because we don't have the .drv
    # path for the derivation.
    # FIXME(jadel): we really should rewrite all this code so it simply knows
    # the derivation hash. See Note [Redesigning Nix input-side integration].
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
        #
        # Note: this is only the *primary* derivation output. Each secondary
        # output's own `NixDynamicInfo` lands in a subtarget.
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
        "outputs": attrs.list(attrs.string(), default = [], doc = """
            Derivation outputs to build, e.g. `["out", "dev"]`. Each one is
            exposed as a sub-target of the same name, and the first one becomes
            the default output.

            When empty (the default), Nix builds the derivation's default
            outputs and this target has a single, unnamed output.
        """),
    },
)

def _read_nix_path_dynamic_impl(
        # starlark-lint-disable unused-argument
        actions: AnalysisActions,  # @unused
        path_file):
    return [NixPathInfo(path = path_file.read_string().strip())]

_read_nix_path_dynamic = dynamic_actions(
    impl = _read_nix_path_dynamic_impl,
    attrs = {
        "path_file": dynattrs.artifact_value(),
    },
)

def nix_dynamic_info_from_path_file(actions: AnalysisActions, path_file: Artifact) -> Provider:
    """
    The canonical way to build a `NixDynamicInfo` for a target that has already
    written its absolute /nix/store path into a file, whatever produced it.
    """
    return NixDynamicInfo(
        dynamic = actions.dynamic_output_new(_read_nix_path_dynamic(path_file = path_file)),
        path_file = path_file,
    )

# FIXME(jadel): this is duplicate logic as in haskell/mercury_haskell.bzl. Needs to be DRY'd up eventually.
def _read_out_link(ctx: AnalysisContext, out_link: Artifact, output: str | None) -> Provider:
    read_link = ctx.actions.declare_output("read_link" if output == None else "read_link-{}".format(output))
    ctx.actions.run(
        cmd_args("bash", "-ec", """readlink $1 | tr -d '\\n' > $2""", "--", out_link, read_link.as_output()),
        category = "nix_path",
        identifier = output,
        local_only = True,
        allow_cache_upload = False,
    )

    return nix_dynamic_info_from_path_file(ctx.actions, read_link)

BinDirInfo = provider(
    doc = """Provides the path of the `/bin` directory of a derivation output.""",
    fields = {
        "args": provider_field(cmd_args),
    },
)

# FIXME(jadel): Unify with a dynamic for `NixDynamicDepsTset`.
#
# A multi-output `nix_build` returns one of these per output as subtargets.
# However, it can't use NixDerivationInfo because we don't have the drv path.
# Alas all this stuff really needs rework.
NixDynamicInfo = provider(
    doc = """Provides nix-side dynamic information. Contains a NixPathInfo provider.""",
    fields = {
        "dynamic": DynamicValue,
        # Same store path as `NixPathInfo.path`, but as a file. Reading the
        # dynamic requires being inside a dynamic action, whereas the file can
        # go straight onto a command line assembled during analysis.
        "path_file": Artifact,
    },
)

def collect_all_nix_output_dynamics_for_target(providers) -> list[DynamicValue]:
    """
    Pulls out the NixDynamicInfo.dynamic for the default output and all
    subtargets carrying NixDynamicInfo.

    `providers` has different types in bxl and analysis so we omit a type
    declaration for it: it's a `Dependency` in rule analysis and a
    `ProviderCollection` from `ctx.analysis(...).providers()` in BXL.
    """
    output_dynamics = [
        sub_providers[NixDynamicInfo].dynamic
        for sub_providers in providers[DefaultInfo].sub_targets.values()
        if NixDynamicInfo in sub_providers
    ]
    if output_dynamics:
        # The primary output's `NixDynamicInfo` will appear in the [out]
        # subtarget, if present, so we need not consider the default
        # NixDynamicInfo if there are NixDynamicInfo in subtargets.
        return output_dynamics

    # Either a single-output `nix_build`, or a rule forwarding one's
    # `NixDynamicInfo` (e.g. `nix_native_lib`).
    if NixDynamicInfo in providers:
        return [providers[NixDynamicInfo].dynamic]

    return []

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
