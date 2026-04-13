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
load(
    "@prelude//cxx:cxx_library_utility.bzl",
    "cxx_attr_exported_linker_flags",
)
load(
    "@prelude//cxx:preprocessor.bzl",
    "cxx_inherited_preprocessor_infos",
    "cxx_merge_cpreprocessors",
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
    "extract_soname_from_shlib",
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

    # Hmmm. This feels kinda nasty but I think it's fine? I guess we might want
    # to replace it with Buck2-built Bash and `readlink` at some point.
    #
    # Note: There's two reasons we use `bash` to run `readlink` instead of
    # using `out_link.project`. The first is that the `Artifact.project`
    # method hard-errors if you attempt to use it on a symlink. The second
    # is that having a link to an absolute path is nice.
    lib_output = ctx.actions.declare_output(lib_filename)
    ctx.actions.run(
        cmd_args(
            "bash",
            "-ec",
            """
            ln -s "$(readlink "$1")/$2" "$3"
            """,
            "--",
            out_link,
            lib_relative_path,
            lib_output.as_output(),
        ),
        category = "symlink",
    )

    providers.append(DefaultInfo(default_output = lib_output))

    pre_flags = []
    pre_flags.extend(cxx_attr_exported_linker_flags(ctx))

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

    # Propagate preprocessor info from dependencies.
    inherited_pp_info = cxx_inherited_preprocessor_infos(ctx.attrs.deps)
    providers.append(cxx_merge_cpreprocessors(
        ctx.actions,
        # TODO: I think we need to fill this in with like, `include` dirs from
        # the `-dev` output of the Nix build? But we can kick that can down the
        # road.
        own = [],
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
    soname = to_soname(extract_soname_from_shlib(
        actions = ctx.actions,
        name = "__soname__.txt",
        shared_lib = lib_output,
    ))
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
