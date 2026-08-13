# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Default Nix-derived toolchains.

This exists to somewhat DRY the amount of stuff which is in our OSS toolchain
vs the internal one. I have complicated feelings about it because it most
definitely makes this stuff less DAMP. Maybe we want to move the base
non-Haskell toolchains to another BUCK file and use a pile of aliases?
"""

load("@prelude//platforms:defs.bzl", "host_configuration")
load("@toolchains//nix:nix_bash_toolchain.bzl", "nix_bash_genrule_toolchain")
load("@toolchains//nix:nix_build.bzl", "nix_build")
load("@toolchains//nix:nix_cxx_toolchain.bzl", "nix_cxx_toolchain")
load("@toolchains//nix:nix_python_toolchain.bzl", "nix_python_bootstrap_toolchain", "nix_python_toolchain")
load("@toolchains//nix:nix_rust_toolchain.bzl", "nix_rust_toolchain")

# This says that a given toolchain cannot be used to cross-compile.
# E.g. if you are building a target for Linux, you will need to execute
# this toolchain on a Linux machine.
exec_compatible_with = [
    select({
        "prelude//os:linux": "prelude//os:linux",
        "prelude//os:macos": "prelude//os:macos",
        "prelude//os:windows": "prelude//os:windows",
        "prelude//os:none": host_configuration.os,
    }),
    select({
        "prelude//cpu:arm64": "prelude//cpu:arm64",
        "prelude//cpu:x86_64": "prelude//cpu:x86_64",
        "prelude//cpu:wasm32": host_configuration.cpu,
    }),
]

# buildifier: disable=unnamed-macro
def default_nix_toolchains():
    c_opt_flags = select({
        "mwb//constraints/build_type[debug]": ["-O0"],
        "mwb//constraints/build_type[release]": ["-O2"],
    })
    nix_cxx_toolchain(
        name = "cxx",
        exec_compatible_with = exec_compatible_with,
        c_flags = c_opt_flags,
        cxx_flags = c_opt_flags,
        link_style = select({
            # shared linking does the fastest link time (does not do work for
            # linking random transitive dependencies on every executable), which is
            # desired for development. however, it's not good for deployment, so we
            # need to be able to change it.
            "mwb//constraints/link_style[auto]": "shared",
            "mwb//constraints/link_style[shared]": "shared",
            "mwb//constraints/link_style[static_pic]": "static_pic",
        }),
        linker_override = select({
            "DEFAULT": None,
            "config//os:none": select({
                "config//cpu:wasm32": "//:nix_wasm_ld",
            }),
        }),
        linker_type_override = select({
            "DEFAULT": None,
            "config//os:none": select({
                "config//cpu:wasm32": "wasm",
            }),
        }),
        visibility = ["PUBLIC"],
    )

    # Not actually used, but needed to avoid an error during `audit visibility`
    # and when querying the graph of a cxx target.
    # See: https://github.com/facebook/buck2-prelude/commit/411f25647c34dee2f5e036d905a318459634ab2b
    native.toolchain_alias(
        name = "cxx_no_default_deps",
        actual = ":cxx",
        visibility = ["PUBLIC"],
    )

    nix_rust_toolchain(
        name = "rust",
        exec_compatible_with = exec_compatible_with,
        rustc_flags =
            select({
                "mwb//constraints/build_type[debug]": ["-Copt-level=0"],
                "mwb//constraints/build_type[release]": ["-Copt-level=3"],
            }) +
            select({
                "prelude//cpu:arm64": select({
                    # Workaround for rustc and buck2 prelude not getting along on
                    # aarch64-linux w.r.t. cxx_library targets:
                    # https://github.com/rust-lang/rust/issues/154975
                    # https://github.com/facebook/buck2/issues/1405
                    #
                    # Buck2 puts the linker args in -Clink-arg where they are
                    # opaque to rustc and get placed after the normal Rust libraries.
                    #   … <rustc .o files> \
                    #    --as-needed -Bstatic <all rlibs> -Bdynamic \
                    #    -lgcc_s -lutil -lrt -lpthread -lm -ldl -lc \      ← rustc's late_link_args; -lc gets --as-needed-dropped here
                    #    --eh-frame-hdr -z noexecstack --gc-sections -z relro -z now \
                    #    <buck's linker_args.txt content:> \
                    #      libring-…-c-asm-elf-aarch64.pic.a \             ← extracts curve25519.c.pic.o → refs __stack_chk_guard
                    #      -rpath … -lcrypto -rpath … -lssl \
                    #    crtendS.o crtn.o \
                    #    -rpath … -rpath …
                    #
                    # Then, if using ld.bfd rather than lld (which facebook almost
                    # certainly uses), --as-needed causes the DSO providing
                    # __stack_chk_guard to get dropped while linking.
                    #
                    # __stack_chk_guard lives in ld-linux-aarch64.so.1 which gets
                    # pulled in via the glibc `libc.so` linker script in
                    # AS_NEEDED(...). That means that if nothing requests a symbol
                    # from `ld-linux` *prior* to `-lc` in link args, `ld-linux`
                    # won't become a dependency. The flags we insert via
                    # `rustc_flags` here still appear before the big file of link
                    # args inserted by the prelude.
                    #
                    # Fix: name ld-linux directly under --no-as-needed so it is
                    # unconditionally linked, no matter the order.
                    "prelude//os:linux": ["-Clink-arg=-Wl,--push-state,--no-as-needed", "-Clink-arg=-l:ld-linux-aarch64.so.1", "-Clink-arg=-Wl,--pop-state"],
                    "DEFAULT": [],
                }),
                "DEFAULT": [],
            }),
        visibility = ["PUBLIC"],
    )

    nix_python_toolchain(
        name = "python",
        exec_compatible_with = exec_compatible_with,
        visibility = ["PUBLIC"],
    )

    nix_python_bootstrap_toolchain(
        name = "python_bootstrap",
        exec_compatible_with = exec_compatible_with,
        visibility = ["PUBLIC"],
    )

    nix_bash_genrule_toolchain(
        name = "genrule",
        exec_compatible_with = exec_compatible_with,
        visibility = ["PUBLIC"],
    )

def default_flake_attrs():
    nix_build(
        name = "nix_cxx",
        attr = "cxx",
        binaries = [
            "ar",
            "cc",
            "c++",
            "nm",
            "objcopy",
            "objdump",
            "ranlib",
            "strip",
        ],
        flake = "@nix//:nix_overlays",
        visibility = ["PUBLIC"],
    )

    nix_build(
        name = "nix_rust",
        attr = "rust",
        binaries = [
            "rustc",
            "clippy-driver",
            "rustdoc",
        ],
        flake = "@nix//:nix_overlays",
    )

    nix_build(
        name = "nix_wasm_ld",
        attr = "wasm-ld",
        binary = "wasm-ld",
        flake = "@nix//:nix_overlays",
    )

    nix_build(
        name = "bash",
        binary = "bash",
        flake = "@nix//:nix_overlays",
        visibility = ["PUBLIC"],
    )

    nix_build(
        name = "python_bootstrap_interpreter",
        attr = "python",
        binary = "python",
        flake = "@nix//:nix_overlays",
    )

    nix_build(
        name = "pyrefly",
        attr = "pyrefly-wrapper",
        binary = "pyrefly",
        flake = "@nix//:nix_overlays",
    )

    nix_build(
        name = "buildifier",
        binaries = [
            "buildozer",
        ],
        binary = "buildifier",
        flake = "@nix//:nix_overlays",
        visibility = ["PUBLIC"],
    )

    nix_build(
        name = "podman",
        attr = "podman",
        binary = "podman",
        flake = "@nix//:nix_overlays",
        target_compatible_with = ["prelude//os:linux"],
        visibility = ["PUBLIC"],
    )
