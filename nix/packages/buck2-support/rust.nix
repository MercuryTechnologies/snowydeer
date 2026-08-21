# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
{
  lib,
  # See Note [GCC driver bugs] in nix/overlays/ghc.nix. We build with
  # `mercury-stdenv` (Mercury's patched gcc) but assert that the *stock*
  # `stdenv.cc` (the unpatched driver) never leaks into the output, so these
  # must stay distinct -- do not alias `stdenv` to `mercury-stdenv`.
  #
  # N.B. We don't carry these GCC patches outside Mercury since we don't have
  # 10k+ Haskell modules to link into one executable.
  stdenv,
  mercury-stdenv ? stdenv,
  makeWrapper, # TODO: `makeBinaryWrapper`?
  fenix,

  # Which Rust to wrap. We ship fenix's stable toolchain plus the standard
  # library for the extra targets we build for; the open source shim overrides
  # these with nixpkgs' `rustc` and `clippy`. Deliberately not named after those
  # attrs, so that `callPackage` can't quietly fill them in and swap the
  # toolchain out from under whoever forgets to override.
  rustToolchain ? fenix.combine [
    fenix.stable.toolchain
    fenix.targets.wasm32-unknown-unknown.stable.rust-std
  ],
  clippyToolchain ? rustToolchain,
}:
let
  isPatchedCc = mercury-stdenv.cc.outPath != stdenv.cc.outPath;
in
mercury-stdenv.mkDerivation {
  name = "buck2-rust";
  dontUnpack = true;
  dontCheck = true;
  nativeBuildInputs = [ makeWrapper ];
  # See Note [GCC driver bugs] in nix/overlays/ghc.nix.
  disallowedRequisites = lib.optionals (isPatchedCc && !stdenv.cc.isClang) [ stdenv.cc ];
  env = {
    RUSTC = rustToolchain;
    CLIPPY = clippyToolchain;
  };
  buildPhase = ''
    function capture_env() {
        # variables to export, all variables with names beginning with one of these are exported
        local -ar vars=(
            NIX_CC_WRAPPER_TARGET_HOST_
            NIX_CFLAGS_COMPILE
            NIX_DONT_SET_RPATH
            NIX_ENFORCE_NO_NATIVE
            NIX_HARDENING_ENABLE
            NIX_IGNORE_LD_THROUGH_GCC
            NIX_LDFLAGS
            NIX_NO_SELF_RPATH
        )
        for prefix in "''${vars[@]}"; do
            for v in $( eval 'echo "''${!'"$prefix"'@}"' ); do
                echo "--set"
                echo "$v"
                echo "''${!v}"
            done
        done
    }

    # Same self-rpath bug as cxx.nix: strip -rpath $out/lib before capture so
    # it doesn't leak into the RUNPATH of every binary linked by this toolchain.
    # The $out/lib symlink exists for buck rules to embed a relative buck-out
    # path, not to add an rpath.
    NIX_LDFLAGS=$(echo "$NIX_LDFLAGS" | sed "s|-rpath $out/lib||g")

    mkdir -p "$out/bin"

    # The rustc here may be a wrapper (if it's nixpkgs rustc) which has no
    # adjacent lib directory so we need to ask, or it may be a fenix combined
    # toolchain, in which case there is an adjacent lib dir, but we can also
    # just ask.
    #
    # This lib symlink is ultimately used to force the sysroot to a buck-out
    # path to avoid spurious nix dependencies.
    ln -s "$($RUSTC/bin/rustc --print sysroot)/lib" "$out/lib"

    mapfile -t < <(capture_env)

    makeWrapper "$RUSTC/bin/rustc" "$out/bin/rustc" "''${MAPFILE[@]}"
    makeWrapper "$RUSTC/bin/rustdoc" "$out/bin/rustdoc" "''${MAPFILE[@]}"
    makeWrapper "$CLIPPY/bin/clippy-driver" "$out/bin/clippy-driver" "''${MAPFILE[@]}"
    makeWrapper "$CLIPPY/bin/cargo-clippy" "$out/bin/cargo-clippy" "''${MAPFILE[@]}"
  '';

  meta.description = "rust toolchain for buck2, similar in structure to buck2-toolchain.cxx";
}
