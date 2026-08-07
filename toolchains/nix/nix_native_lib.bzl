# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Provide a Nix-built library to Buck2 so it can be linked against and
propagated through `deps` lists correctly.
"""

load(
    "@buck2-haskell//:link_info.bzl",
    "ExtraGhcLinkerFlagsInfo",
    "GhcLinkableInfo",
)
load("@prelude//cxx:cxx_context.bzl", "get_cxx_toolchain_info")
load("@prelude//cxx:cxx_toolchain_types.bzl", "LinkerType")
load(
    "@prelude//cxx:preprocessor.bzl",
    "CPreprocessor",
    "CPreprocessorArgs",
    "cxx_inherited_preprocessor_infos",
    "cxx_merge_cpreprocessors",
    "format_system_include_arg",
)
load("@prelude//decls:cxx_common.bzl", "cxx_common")
load("@prelude//linking:link_groups.bzl", "merge_link_group_lib_info")
load(
    "@prelude//linking:link_info.bzl",
    "LibOutputStyle",
    "LinkInfo",
    "LinkInfos",
    "LinkedObject",
    "SharedLibLinkable",
    "create_merged_link_info",
    "to_link_strategy",
)
load(
    "@prelude//linking:linkable_graph.bzl",
    "create_linkable_graph",
    "create_linkable_graph_node",
    "create_linkable_node",
)
load(
    "@prelude//linking:shared_libraries.bzl",
    "SharedLibraries",
    "SharedLibraryInfo",
    "create_shlib_from_ctx",
    "merge_shared_libraries",
    "to_soname",
)
load("@prelude//linking:types.bzl", "Linkage")
load("@prelude//unix:providers.bzl", "UnixEnv", "create_unix_env_info")
load("@prelude//utils:utils.bzl", "filter_and_map_idx")
load(":nix_build.bzl", "NixDynamicInfo", "NixPathInfo")

def _write_rpath_ld_args_impl(
        actions: AnalysisActions,
        path: ResolvedDynamicValue,
        output: OutputArtifact) -> list[Provider]:
    rpath = path.providers[NixPathInfo].path + "/lib"
    args = cmd_args("-rpath", rpath)
    args_final = cmd_args(cmd_args(args, delimiter = ","), format = "-Wl,{}")
    actions.write(output, args_final)
    return [ExtraGhcLinkerFlagsInfo(flags = [args])]

_write_rpath_ld_args = dynamic_actions(
    impl = _write_rpath_ld_args_impl,
    attrs = {
        "path": dynattrs.dynamic_value(),
        "output": dynattrs.output(),
    },
)

def _symlink_into_nix_output(
        ctx: AnalysisContext,
        out_link: Artifact,
        relative_path: str,
        output_name: str,
        category: str) -> Artifact:
    """
    Turn an out-link plus a path relative to the Nix output it points at into a
    buck-out artifact symlinked at the absolute store path.
    """

    # Hmmm. This feels kinda nasty but I think it's fine? I guess we might want
    # to replace it with Buck2-built Bash and `readlink` at some point.
    #
    # Note: There's two reasons we use `bash` to run `readlink` instead of
    # using `out_link.project`. The first is that the `Artifact.project`
    # method hard-errors if you attempt to use it on a symlink. The second
    # is that having a link to an absolute path is nice.
    #
    # `ln -s` happily creates a dangling link, and a dangling link is a
    # perfectly cacheable action result, so we check it to catch mistakes
    # early.
    output = ctx.actions.declare_output(output_name)
    ctx.actions.run(
        cmd_args(
            "bash",
            "-ec",
            """
            target="$(readlink "$1")/$2"
            if [[ ! -e "$target" ]]; then
                echo "nix_native_lib: $target does not exist" >&2
                exit 1
            fi
            ln -s "$target" "$3"
            """,
            "--",
            out_link,
            relative_path,
            output.as_output(),
        ),
        category = category,
        allow_cache_upload = False,
        local_only = True,
    )
    return output

def _extract_soname(ctx: AnalysisContext, shared_lib: Artifact) -> Artifact:
    """
    The `DT_SONAME` of an ELF shared library.

    This is the prelude's `extract_soname_from_shlib` but using objdump
    hermetically.
    """
    output = ctx.actions.declare_output("__soname__.txt")
    ctx.actions.run(
        cmd_args(
            "bash",
            "-ec",
            """
            soname=$("$1" -p "$2" | while read -r key value _; do
                if [[ "$key" == SONAME ]]; then
                    echo "$value"
                fi
            done)
            if [[ -z "$soname" ]]; then
                echo "nix_native_lib: $2 has no DT_SONAME" >&2
                exit 1
            fi
            echo "$soname" > "$3"
            """,
            "--",
            ctx.attrs._objdump[RunInfo],
            shared_lib,
            output.as_output(),
        ),
        category = "extract_soname",
        identifier = shared_lib.short_path,
        # The library is an external symlink into the Nix store, so this can
        # only run where that store is.
        local_only = True,
        allow_cache_upload = False,
    )
    return output

def _nix_native_lib_impl(ctx: AnalysisContext):
    # This rule emits providers for a Nix-built native library as if you had
    # built it with a `cxx_library` rule. This makes it linkable for other
    # rules, transitively.
    #
    # This was written with reference to two pieces of the prelude.
    #
    # The first is `LinkableProviders` from `prelude//linking/linkables.bzl` [1].
    # This is described as:
    #
    # > A record containing all provider types used for linking in the prelude.
    # > This is essentially the minimal subset of a "linkable" `dependency`
    # > that user rules need to implement linking, and avoids needing functions
    # > to take the heavier- weight `dependency` type.
    #
    # The listed providers are `LinkGroupLibInfo`, `LinkableGraph`,
    # `MergedLinkInfo`, `SharedLibraryInfo`, and `LinkableRootInfo`. These are
    # the providers we need to return to make our libraries visible to other
    # Buck2 prelude rules.
    #
    # The second piece of the prelude is the implementation of the
    # `prebuilt_apple_framework` rule in
    # `prelude//apple/prebuilt_apple_framework.bzl` [2]. That code does
    # basically the same thing we're doing here: synthesizing providers for
    # libraries built outside of Buck2. This was very helpful in determining
    # which attributes of the providers we can safely omit.
    #
    # We also used `buck2 audit providers` with a `cxx_library` target from the
    # Buck2 repo upstream to see what the values of these attributes are in
    # practice.
    #
    # [1]: https://github.com/MercuryTechnologies/buck2-prelude/blob/b19295e68de8455e0be58c1ad678665fcfd81a74/linking/linkables.bzl#L27-L37
    # [2]: https://github.com/facebook/buck2/blob/efa4555e4b6e81d1b438bea0ea99bdc6b35c2621/prelude/apple/prebuilt_apple_framework.bzl#L114-L155
    #
    # After initially writing this, we found some more useful rules to look at:
    # - pkgconfig: you *can* have not-known-at-compile-time linker/compiler args by using response files with "@":
    #   https://github.com/mercurytechnologies/buck2-prelude/blob/f1a54cfb5bfcef296b7cc55ccb9193a22bb30cff/third-party/pkgconfig.bzl#L79-L87
    # - prebuilt_cxx_library: more complex usage of this stuff, almost
    #   identical to what we're doing, but not library-ized, so we probably don't
    #   want to use it for flexibility reasons.
    #   https://github.com/MercuryTechnologies/buck2-prelude/blob/e7d1be49af6120ca47be9b754392a6bc176df679/cxx/cxx.bzl#L365-L702

    cxx_toolchain = get_cxx_toolchain_info(ctx)

    # we force these to shared linkage as usually system libraries don't *have*
    # static variants.
    preferred_linkage = Linkage("shared")

    # What if there's more than 1 `default_outputs`?
    out_link = ctx.attrs.input[DefaultInfo].default_outputs[0]

    # E.g. `heif`.
    lib_name = ctx.attrs.lib_name

    # E.g. `libheif.dylib`.
    lib_filename = cxx_toolchain.linker_info.shared_library_name_format.format(
        cxx_toolchain.linker_info.shared_library_name_default_prefix + lib_name,
    )

    # E.g. `lib/libheif.dylib`.
    lib_relative_path = "lib/" + lib_filename
    nix_dyn_info = ctx.attrs.input.get(NixDynamicInfo)

    providers = []

    lib_output = _symlink_into_nix_output(
        ctx,
        out_link = out_link,
        relative_path = lib_relative_path,
        output_name = lib_filename,
        category = "symlink",
    )

    # The directory to put on the header search path, e.g. the `include` of the
    # `dev` output, holding `libheif/heif.h`.
    #
    # FIXME(jadel): I have conflicted feelings about this implementation
    # choice: I wonder if this should actually use pkg-config instead and treat
    # it as an opaque argfile
    # (c.f. this but we'd reimpl it ourselves: https://github.com/facebook/buck2/blob/e44a63727d924b037dcec097c567ffbcc0c78799/prelude/third-party/pkgconfig.bzl),
    # since packages are allowed to put complicated load-bearing nonsense like
    # -D preprocessor defines into the cflags for their consumers (as well as
    # have dependencies whose cflags *also* land in our stuff).
    #
    # For more complicated libraries like libfolly (required for Glean) which
    # have ABI-affecting -D defines, we almost certainly need to get the actual
    # cflags out of pkg-config for safety.
    #
    # Some investigation while writing this turned up that it's ~impossible to
    # call `pkg-config` from buck2 itself, since it requires all the machinery
    # of the nixpkgs stdenv to resolve `Deps` (if any; e.g. libheif depends on
    # libaom). The right way to do this is likely as a `runCommand` derivation
    # defined in the buck2-toolchain that simply runs `pkg-config
    # --cflags` and writes it to the derivation output, then we consume
    # that derivation via nix_build.
    #
    # We may possibly want to skip the `--libs` part and implement it manually
    # in buck2 rather than calling pkg-config, since it means that the shared
    # library machinery of buck2 can't see the libs. Not sure.
    #
    # However, using pkgconfig with a @response_file makes the info more opaque to
    # buck2 itself, which is itself a tradeoff.
    include_dir = None
    if ctx.attrs.include_output != None:
        input_sub_targets = ctx.attrs.input[DefaultInfo].sub_targets
        include_providers = input_sub_targets.get(ctx.attrs.include_output)
        if include_providers == None or NixDynamicInfo not in include_providers:
            fail("`include_output = \"{}\"` does not name an output of {}; add it to that target's `outputs`.".format(
                ctx.attrs.include_output,
                ctx.attrs.input.label,
            ))
        include_out_link = include_providers[DefaultInfo].default_outputs[0]
        include_dir = _symlink_into_nix_output(
            ctx,
            out_link = include_out_link,
            relative_path = ctx.attrs.include_subdir,
            output_name = "include",
            category = "symlink_include",
        )

    providers.append(DefaultInfo(
        default_output = lib_output,
        sub_targets = {} if include_dir == None else {"include": [DefaultInfo(default_output = include_dir)]},
    ))

    pre_flags = []
    pre_flags.extend(ctx.attrs.exported_linker_flags)

    if nix_dyn_info:
        providers.append(nix_dyn_info)

        ld_args_output = ctx.actions.declare_output(lib_name + ".ld_args")
        if ctx.attrs.wrap_rpath_ld_flags:
            pre_flags.append(cmd_args(ld_args_output, format = "@{}"))

        rpath_ld_args_dynamic = ctx.actions.dynamic_output_new(
            _write_rpath_ld_args(
                path = nix_dyn_info.dynamic,
                output = ld_args_output.as_output(),
            ),
        )
        providers.append(GhcLinkableInfo(
            extra_ghc_linker_flags_dynamic = rpath_ld_args_dynamic,
        ))

    # See: https://github.com/facebook/buck2/blob/efa4555e4b6e81d1b438bea0ea99bdc6b35c2621/prelude/apple/prebuilt_apple_framework.bzl#L89-L210
    link_info = LinkInfo(
        name = lib_name,
        linkables = [
            # TODO: This doesn't (yet) support static libs.
            SharedLibLinkable(
                lib = lib_output,
                link_without_soname = True,
            ),
        ],
        pre_flags = pre_flags,
    )
    link_infos = LinkInfos(default = link_info)

    output_style_link_infos = {LibOutputStyle("shared_lib"): link_infos}

    # Propagate preprocessor info from dependencies, plus our own include dir if
    # we have one.
    #
    # We pass the include dir as a plain `-isystem <dir>` in
    # `CPreprocessorArgs.args`, matching `prebuilt_cxx_library`. We have to use
    # a relatively opaque arg due to the other options requiring greater a
    # priori knowledge of the structure of the output.
    #
    # We point `-isystem` at the buck-out symlink rather than the absolute
    # `/nix/store` path on purpose: that registers a real input (so the Nix
    # build is ordered before the compile) and keeps dep-file entries inside the
    # build root. Absolute out-of-root paths are silently discarded by the
    # prelude's `dep_file_utils.py`, which would lose header change tracking.
    #
    # Note: Haskell targets don't yet see these. We plan to implement a rule to
    # generate package.conf rules for these so that they can be fed into
    # haskell rules as normal.
    own_pp = []
    if include_dir != None:
        isystem = format_system_include_arg(
            cmd_args(include_dir),
            cxx_toolchain.cxx_compiler_info.compiler_type,
        )
        own_pp.append(CPreprocessor(
            args = CPreprocessorArgs(args = isystem, precompile_args = isystem),
        ))

    inherited_pp_info = cxx_inherited_preprocessor_infos(ctx.attrs.deps)
    providers.append(cxx_merge_cpreprocessors(
        ctx.actions,
        own = own_pp,
        xs = inherited_pp_info,
    ))

    linked_object = LinkedObject(
        output = lib_output,
        unstripped_output = lib_output,
    )

    # Note: see `prebuilt_cxx_library_impl` in `prelude//cxx:cxx.bzl` for
    # another example of this.
    #
    # The soname field here is used to determine the name at which a library
    # will appear in the build_shared_libs_for_symlink_tree tree when consumed
    # by a Rust or C++ target.
    #
    # See: link-removed
    #
    # We only extract the real soname on ELF platforms, where it actually
    # differs from the filename (`libheif.so.1` vs. `libheif.so`) and has to
    # match the `DT_NEEDED` entry.
    #
    # A Mach-O dylib has an `LC_ID_DYLIB` install name (which is absolute under
    # Nix) instead of a `DT_SONAME`. Thus on macOS we fall back to the plain
    # filename, which is what `prebuilt_cxx_library` does by default (its
    # `extract_soname` attr is `False`).
    if cxx_toolchain.linker_info.type == LinkerType("gnu"):
        soname = to_soname(_extract_soname(ctx, lib_output))
    else:
        soname = to_soname(lib_filename)

    solibs = [
        create_shlib_from_ctx(
            ctx,
            lib = linked_object,
            soname = soname,
        ),
    ]
    shared_libs = SharedLibraries(libraries = solibs)

    # Packaging information used by e.g. snowydeer to make Nix packages.
    providers.append(
        create_unix_env_info(
            actions = ctx.actions,
            env = UnixEnv(
                label = ctx.label,
                native_libs = [shared_libs],
            ),
            deps = ctx.attrs.deps,
        ),
    )

    providers.append(
        # > The LinkableGraph for a target holds all the transitive nodes,
        # > roots, and exclusions from all of its dependencies.
        create_linkable_graph(
            ctx = ctx,
            node = create_linkable_graph_node(
                ctx = ctx,
                linkable_node = create_linkable_node(
                    ctx = ctx,
                    preferred_linkage = preferred_linkage,
                    default_link_strategy = to_link_strategy(cxx_toolchain.linker_info.link_style),
                    link_infos = output_style_link_infos,
                    # FIXME(jadel): what is this for?
                    default_soname = None,
                    shared_libs = shared_libs,
                ),
                # What does this do? Why is this needed??
                excluded = {ctx.label: None},
            ),
            # TODO: This has some other args like `deps` that it seems like we
            # should be passing, but the upstream `prebuilt_apple_framework`
            # doesn't bother, so I guess this is fine...?
        ),
    )

    # > A map of native linkable infos from transitive dependencies for
    # > each LinkStrategy. This contains the information about how to link
    # > in a target for each link strategy. This doesn't contain the
    # > information about things needed to package the linked result
    # > (i.e. this doesn't contain the information needed to know what
    # > shared libs needed at runtime for the final result).
    merged_link_info = create_merged_link_info(
        ctx = ctx,
        pic_behavior = get_cxx_toolchain_info(ctx).pic_behavior,
        preferred_linkage = preferred_linkage,
        link_infos = output_style_link_infos,
    )
    providers.append(merged_link_info)

    providers.append(merge_link_group_lib_info(deps = ctx.attrs.deps))
    providers.append(
        merge_shared_libraries(
            actions = ctx.actions,
            node = shared_libs,
            deps = filter_and_map_idx(SharedLibraryInfo, ctx.attrs.deps),
        ),
    )

    # TODO: A `LinkableRootInfo` is probably not needed here...?

    return providers

_attrs = (
    cxx_common.exported_linker_flags_arg() |
    {
        "input": attrs.dep(doc = """
            A `nix.rules.flake` (`toolchains//nix.bzl`) target which contains
            the library that this rule will provide.
        """),
        "lib_name": attrs.string(doc = """
            The library to provide, e.g. `heif` for `lib/libheif.dylib` on
            macOS and `lib/libheif.so` on Linux.
        """),
        "deps": attrs.list(attrs.dep(), default = [], doc = """
            Transitive dependencies needed to link against this library.
        """),
        "include_output": attrs.option(attrs.string(), default = None, doc = """
            The Nix output of `input` holding this library's headers, e.g.
            `dev`. `input` must list it in its `outputs` so that it's available
            as a sub-target.

            If unset, this rule provides no headers to its dependents.
        """),
        "include_subdir": attrs.string(default = "include", doc = """
            The subdirectory of `include_output` to add to the header search
            path.
        """),
        "wrap_rpath_ld_flags": attrs.bool(default = False, doc = """
            Wrap the absolute nix store library path into an argfile in order to pass -rpath and pre_flag configured with @argfile.
        """),
        # Copied from `prelude//:rules_impl.bzl`.
        # See: https://github.com/MercuryTechnologies/buck2-prelude/blob/b19295e68de8455e0be58c1ad678665fcfd81a74/rules_impl.bzl#L444-L451
        "preferred_linkage": attrs.enum(
            Linkage.values(),
            default = "any",
            doc = """
            Determines what linkage is used when the library is depended on by another target. To
            control how the dependencies of this library are linked, use `link_style` instead.
            """,
        ),

        # `create_linkable_node` crashes unless this is defined. This is legacy
        # nonsense and is not actually related to Buck2 labels at all! These are
        # just opaque string 'tags'.
        #
        # The prelude describes this attr as:
        #
        # > Set of arbitrary strings which allow you to annotate a `build rule`
        # > with tags that can be searched for over an entire dependency tree using
        # > `buck query()`
        #
        # See: https://github.com/MercuryTechnologies/buck2-prelude/blob/b19295e68de8455e0be58c1ad678665fcfd81a74/decls/common.bzl#L125-L132
        "labels": attrs.default_only(attrs.list(attrs.string(), default = [])),
        "_cxx_toolchain": attrs.default_only(attrs.toolchain_dep(default = "toolchains//:cxx")),
        # Only used on ELF platforms, to read `DT_SONAME`.
        # `BinaryUtilitiesInfo` (bafflingly) has no field for `objdump` so we need
        # to directly reference the binary.
        "_objdump": attrs.default_only(attrs.exec_dep(default = "toolchains//:nix_cxx[objdump]")),
    }
)

nix_native_lib = rule(
    impl = _nix_native_lib_impl,
    doc = """
        Provide a Nix-built library to Buck2 so it can be linked against and
        propagated through `deps` lists correctly.
    """,
    attrs = _attrs,
)
