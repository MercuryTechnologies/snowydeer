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

def default_nix_toolchains():
    nix_cxx_toolchain(
        name = "cxx",
        exec_compatible_with = exec_compatible_with,
        link_style = select({
            # shared linking does the fastest link time (does not do work for
            # linking random transitive dependencies on every executable), which is
            # desired for development. however, it's not good for deployment, so we
            # need to be able to change it.
            "DEFAULT": "shared",
            "root//constraints/link_style:shared": "shared",
            "root//constraints/link_style:static_pic": "static_pic",
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

    nix_rust_toolchain(
        name = "rust",
        exec_compatible_with = exec_compatible_with,
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
