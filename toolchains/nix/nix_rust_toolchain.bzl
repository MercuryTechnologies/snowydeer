# SPDX-FileCopyrightText: 2025 Meta Platforms, Inc.
# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Much of this is copy pasted from prelude//toolchains/rust.bzl, with the
notable difference being that the particular compiler, rustdoc and
clippy-driver are from nix rather than from $PATH.

https://github.com/facebook/buck2-prelude/blob/ed02ea37955ef0dddf29aaee961e9bc2c0a33891/toolchains/rust.bzl
"""

load("@prelude//rust:rust_toolchain.bzl", "PanicRuntime", "RustToolchainInfo")

# annoying copy pasta because it's not a public symbol
_DEFAULT_TRIPLE = select({
    "config//os:linux": select({
        "config//cpu:arm64": "aarch64-unknown-linux-gnu",
        "config//cpu:x86_64": "x86_64-unknown-linux-gnu",
    }),
    "config//os:macos": select({
        "config//cpu:arm64": "aarch64-apple-darwin",
        "config//cpu:x86_64": "x86_64-apple-darwin",
    }),
    "config//os:windows": select({
        "config//cpu:arm64": select({
            # Rustup's default ABI for the host on Windows is MSVC, not GNU.
            # When you do `rustup install stable` that's the one you get. It
            # makes you opt in to GNU by `rustup install stable-gnu`.
            "DEFAULT": "aarch64-pc-windows-msvc",
            "config//abi:gnu": "aarch64-pc-windows-gnu",
            "config//abi:msvc": "aarch64-pc-windows-msvc",
        }),
        "config//cpu:x86_64": select({
            "DEFAULT": "x86_64-pc-windows-msvc",
            "config//abi:gnu": "x86_64-pc-windows-gnu",
            "config//abi:msvc": "x86_64-pc-windows-msvc",
        }),
    }),
    "config//os:none": select({
        "config//cpu:wasm32": "wasm32-unknown-unknown",
    }),
})

def _nix_rust_toolchain(ctx: AnalysisContext) -> list[Provider]:
    nix_rust = ctx.attrs.nix_rust[DefaultInfo].sub_targets

    compiler = nix_rust["rustc"][RunInfo]
    rustdoc = nix_rust["rustdoc"][RunInfo]
    clippy_driver = nix_rust["clippy-driver"][RunInfo]
    return [
        DefaultInfo(),
        RustToolchainInfo(
            allow_lints = ctx.attrs.allow_lints,
            clippy_driver = RunInfo(args = [clippy_driver]),
            clippy_toml = ctx.attrs.clippy_toml[DefaultInfo].default_outputs[0] if ctx.attrs.clippy_toml else None,
            compiler = RunInfo(args = [compiler]),
            default_edition = ctx.attrs.default_edition,
            panic_runtime = PanicRuntime("unwind"),
            deny_lints = ctx.attrs.deny_lints,
            doctests = ctx.attrs.doctests,
            nightly_features = ctx.attrs.nightly_features,
            report_unused_deps = ctx.attrs.report_unused_deps,
            rustc_binary_flags = ctx.attrs.rustc_binary_flags,
            rustc_flags = ctx.attrs.rustc_flags,
            rustc_target_triple = ctx.attrs.rustc_target_triple,
            rustc_test_flags = ctx.attrs.rustc_test_flags,
            rustdoc = RunInfo(args = [rustdoc]),
            rustdoc_flags = ctx.attrs.rustdoc_flags,

            # Explicitly setting the sysroot fixes two separate problems causing
            # gratuitous nix store references to the Rust toolchain.
            #
            # One of them was references appearing in the .data section due to
            # panic messages for various std functions. This is related to the
            # sysroot. By default, rustc finds its sysroot relative to the rustc
            # executable: this means an absolute /nix/store path, which then lands
            # in snowydeer outputs and causes dependency bloat.
            #
            # The other one was references appearing in debuginfo (at least on
            # macOS), which were referencing the static libraries in the sysroot.
            # Same deal as the panic messages. Buck already handles buck-out paths
            # in debuginfo fine (`-oso_prefix .` relativizes debuginfo paths to .
            # on macOS; that happens by default on Linux) so we can fix the problem
            # by ensuring the reference goes through a relative path rather than an
            # absolute one.
            #
            # To verify these problems, build a `snowydeer_package` rule and
            # call `nix path-info --json` on the output and audit that the
            # `references` field doesn't include a Rust compiler.
            #
            # For example, after removing the `sysroot_path` field:
            #
            #     $ nix path-info --json $(cat $(buck bxl //snowydeer/snowydeer.bxl:main -- --target //tools/bwat/bin:package)) | jq
            #     BXL SUCCEEDED
            #     [
            #       {
            #         "ca": "fixed:r:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            #         "narHash": "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=",
            #         "narSize": 24825784,
            #         "path": "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package",
            #         "references": [
            #           "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-libiconv-109",
            #           "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-rust-mixed"
            #         ],
            #         "registrationTime": 1785952833,
            #         "ultimate": true,
            #         "valid": true
            #       }
            #     ]
            #
            # Here, `/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-rust-mixed` is
            # a ~300MB path containing `rustc`, `cargo`, associated libraries,
            # etc.
            sysroot_path = ctx.attrs.nix_rust[DefaultInfo].default_outputs[0],
            warn_lints = ctx.attrs.warn_lints,
        ),
    ]

nix_rust_toolchain = rule(
    impl = _nix_rust_toolchain,
    attrs = {
        "nix_rust": attrs.dep(
            default = "//:nix_rust",
        ),
        "allow_lints": attrs.list(attrs.string(), default = []),
        "clippy_toml": attrs.option(attrs.dep(providers = [DefaultInfo]), default = None),
        "default_edition": attrs.string(default = "2024"),
        "deny_lints": attrs.list(attrs.string(), default = []),
        "doctests": attrs.bool(default = False),
        "nightly_features": attrs.bool(default = False),
        "report_unused_deps": attrs.bool(default = False),
        "rustc_binary_flags": attrs.list(attrs.arg(), default = []),
        "rustc_flags": attrs.list(attrs.arg(), default = []),
        "rustc_target_triple": attrs.string(default = _DEFAULT_TRIPLE),
        "rustc_test_flags": attrs.list(attrs.arg(), default = []),
        "rustdoc_flags": attrs.list(attrs.arg(), default = []),
        "warn_lints": attrs.list(attrs.string(), default = []),
    },
    is_toolchain_rule = True,
)
