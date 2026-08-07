# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{
  lib,
  stdenv,
  makeWrapper,
  writeShellScriptBin,

  compilerName,
  cache-hook,

  # keep-sorted start
  bash,
  buck2-source,
  buildifier,
  cacert,
  clippy,
  coreutils,
  darwin,
  git,
  gnused,
  haskell,
  nix,
  nix-prefetch-docker,
  pyrefly-wrapper,
  python3,
  ripgrep,
  rustc,
  skopeo,
  watchman,
# keep-sorted end
}:
let
  toolchainLibraries = import ./ghc-toolchain-libraries.nix;

  hsPkgs = haskell.packages.${compilerName};

  haskellPackages =
    let
      packages = builtins.map (n: hsPkgs."${n}") toolchainLibraries;
      isHaskellLibrary = p: p ? isHaskellLibrary;
    in
    builtins.listToAttrs (
      builtins.map (p: {
        "name" = p.pname;
        "value" = p.drvPath;
      }) (builtins.filter isHaskellLibrary (lib.closePropagation packages))
    );

  buck2BuildInputs =
    [
      bash
      coreutils
      cacert
      gnused
      git
      nix
      # used by buck2 itself
      watchman
    ]
    ++ lib.optionals stdenv.isDarwin [
      stdenv.cc.bintools
      darwin.cctools
    ];
in
{
  cxx = stdenv.mkDerivation {
    name = "buck2-cxx";
    dontUnpack = true;
    dontCheck = true;
    nativeBuildInputs = [ makeWrapper ];
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

      # The stdenv setup adds -rpath $out/lib to NIX_LDFLAGS (the "self-rpath")
      # before buildPhase runs. capture_env bakes NIX_LDFLAGS into the cc/c++
      # wrappers, so without this strip every binary linked by this toolchain
      # inherits buck2-cxx/lib in its RUNPATH — even though that directory does
      # not exist.
      NIX_LDFLAGS=$(echo "$NIX_LDFLAGS" | sed "s|-rpath $out/lib||g")

      mkdir -p "$out/bin"

      for tool in ar nm objcopy ranlib strip; do
          ln -st "$out/bin" "$NIX_CC/bin/$tool"
      done

      mapfile -t < <(capture_env)

      makeWrapper "$NIX_CC/bin/$CC" "$out/bin/cc" "''${MAPFILE[@]}"
      makeWrapper "$NIX_CC/bin/$CXX" "$out/bin/c++" "''${MAPFILE[@]}"
    '';
  };

  rust = stdenv.mkDerivation {
    name = "buck2-rust";
    dontUnpack = true;
    dontCheck = true;
    nativeBuildInputs = [ makeWrapper ];
    env = {
      RUSTC = rustc;
      CLIPPY = clippy;
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

      # Same self-rpath bug as the cxx derivation above: strip -rpath $out/lib
      # before capture so it doesn't leak into the RUNPATH of every binary
      # linked by this toolchain. The $out/lib symlink exists for buck rules to
      # embed a relative buck-out path, not to add an rpath.
      NIX_LDFLAGS=$(echo "$NIX_LDFLAGS" | sed "s|-rpath $out/lib||g")

      mkdir -p "$out/bin"
      ln -s "$($RUSTC/bin/rustc --print sysroot)/lib" "$out/lib"

      mapfile -t < <(capture_env)

      makeWrapper "$RUSTC/bin/rustc" "$out/bin/rustc" "''${MAPFILE[@]}"
      makeWrapper "$RUSTC/bin/rustdoc" "$out/bin/rustdoc" "''${MAPFILE[@]}"
      makeWrapper "$CLIPPY/bin/clippy-driver" "$out/bin/clippy-driver" "''${MAPFILE[@]}"
      makeWrapper "$CLIPPY/bin/cargo-clippy" "$out/bin/cargo-clippy" "''${MAPFILE[@]}"
    '';

    meta.description = "rust toolchain for buck2, similar in structure to buck2-toolchain.cxx";
  };

  inherit haskellPackages;
  inherit (hsPkgs) ghc;

  bash = writeShellScriptBin "bash" ''
    export PATH='${lib.makeSearchPath "bin" buck2BuildInputs}'
    exec "$BASH" "$@"
  '';

  python = python3;
  inherit
    # keep-sorted start
    buck2-source # just so it gets uploaded to cache
    buildifier
    nix-prefetch-docker
    pyrefly-wrapper
    ripgrep
    skopeo
    # keep-sorted end
    ;

  inherit (hsPkgs)
    hspec-discover
    ;

  cache-hook = cache-hook {
    destination = "s3://cache.oss.mercury.com";
    # XXX(jadel): this is really nasty, but we don't really have a better way
    # to do it, since the cache hook ideally takes an absolute path
    secretKey = "/tmp/mercury-ci/keys/oss-signing-key";
  };
}
