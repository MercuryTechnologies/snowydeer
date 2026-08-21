# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{
  lib,
  stdenv,
  writeShellScriptBin,
  writeText,

  compilerName,
  cache-hook,

  snowydeer,

  # keep-sorted start
  bash,
  buck2-change-detector,
  buck2-source,
  buck2-support,
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
  podman,
  protobuf,
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

  # Every haskellPackages derivation path, formatted so it can be piped
  # into nix derivation show --stdin
  #
  # This exists so the nix_drv action can be a nix build of a single flake
  # attribute, leveraging the eval cache (when used with the nix store add-path
  # in the rules).
  #
  # unsafeDiscardOutputDependency so we don't actually build the package set.
  haskellPackagesDrvPaths = writeText "haskell-packages-drv-paths" (
    lib.concatMapStringsSep "\n" (drv: builtins.unsafeDiscardOutputDependency drv + "^*") (
      builtins.attrValues haskellPackages
    )
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
  inherit (buck2-support) cxx;

  # We ship the toolchains with fenix internally, but that's unnecessary
  # complexity for OSS which can just use the nixpkgs toolchains.
  rust = buck2-support.rust.override {
    rustToolchain = rustc;
    clippyToolchain = clippy;
  };

  inherit haskellPackages haskellPackagesDrvPaths;
  inherit (hsPkgs) ghc;

  bash = writeShellScriptBin "bash" ''
    export PATH='${lib.makeSearchPath "bin" buck2BuildInputs}'
    exec "$BASH" "$@"
  '';

  # FIXME(jadel): we have to use nix's grpcio here to avoid hacks for libcxx
  # with elk:
  # https://github.com/cormacrelf/elk/issues/6
  # grpcio (which brings protobuf): nix_realiser_worker needs it to serve the
  # buck2 worker protocol.
  python = python3.withPackages (ps: with ps; [ grpcio ]);

  libstdcxx = lib.getLib stdenv.cc.cc;

  inherit
    # keep-sorted start
    buck2-change-detector
    buck2-source # just so it gets uploaded to cache
    buildifier
    git
    nix-prefetch-docker
    podman
    protobuf
    pyrefly-wrapper
    ripgrep
    skopeo
    # keep-sorted end
    ;

  inherit (hsPkgs)
    hspec-discover
    ;

  # Expose snowydeer.build-container under the buck2 toolchain so that it can
  # be referenced hermetically in build rules.
  inherit snowydeer;

  cache-hook = cache-hook {
    destination = "s3://cache.oss.mercury.com";
    # XXX(jadel): this is really nasty, but we don't really have a better way
    # to do it, since the cache hook ideally takes an absolute path
    secretKey = "/tmp/mercury-ci/keys/oss-signing-key";
  };
}
