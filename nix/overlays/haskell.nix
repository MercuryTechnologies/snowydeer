# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

final: prev:
let
  inherit (prev) lib;

  ghcVer = final.mercury.compilerName;

  hsOpenTelemetrySrc = final.fetchFromGitHub {
    owner = "iand675";
    repo = "hs-opentelemetry";
    rev = "f9d78fbe89da9e5c149c60a2ba7d75acb471942e";
    hash = "sha256-oBrmeqoltrIfPUhsgtgoahgHi85iBa3H5p6PkiHeKTU=";
  };

  makeHaskellOverlay = overlay: {
    haskell = prev.haskell // {
      packages = prev.haskell.packages // {
        ${ghcVer} = prev.haskell.packages."${ghcVer}".override (oldArgs: {
          overrides = prev.lib.composeExtensions (oldArgs.overrides or (_: _: { })) overlay;
        });
      };
    };
  };

  # Custom GHC 9.10 has API changes and haskell packages need to be adjusted.
  # Eventually, the custom changes are all merged into the GHC upstream.
  overlayForCustomGHC910 = hfinal: hprev: {
    # fixed_nodes change
    doctest = final.haskell.lib.compose.overrideCabal (drv: {
      src = final.applyPatches {
        src = hprev.doctest.src;
        patches = [ ./ghc/patches/9.10/doctest-fixed_nodes-adjustment.patch ];
      };
      # check uses cabal
      doCheck = false;
    }) hprev.doctest;
  };

  versionOverrides = hfinal: _hprev: {
    thread-utils-finalizers = hfinal.callHackageDirect {
      pkg = "thread-utils-finalizers";
      ver = "0.1.1.0";
      sha256 = "1nc7rpclmpyxzqlx5prl40qs0habiqnr3jpdxmjna48555vbzirq";
      rev = {
        revision = "0";
        sha256 = "24944b71d9f1d01695a5908b4a3b44838fab870883114a323336d537995e0a5b";
      };
    } { };
    thread-utils-context = hfinal.callHackageDirect {
      pkg = "thread-utils-context";
      ver = "0.4.1.0";
      sha256 = "0b5jcfnrf3rss6kbcdg7q1mhlnn4405zfd6b5w9qv3nmn7vw3mks";
      rev = {
        revision = "0";
        sha256 = "1de6cceba464ed69689bebf3b3a6867747a6b32fde9a56360dcbe8c555f23981";
      };
    } { };
    hs-opentelemetry-api-types =
      hfinal.callCabal2nix "hs-opentelemetry-api-types" "${hsOpenTelemetrySrc}/api-types"
        { };
    hs-opentelemetry-semantic-conventions =
      hfinal.callCabal2nix "hs-opentelemetry-semantic-conventions"
        "${hsOpenTelemetrySrc}/semantic-conventions"
        { };
    hs-opentelemetry-api = hfinal.callCabal2nix "hs-opentelemetry-api" "${hsOpenTelemetrySrc}/api" { };
  };

  # FIXME(jadel): maybe we should upstream this to nixpkgs, maybe we should eliminate it altogether.
  # https://github.com/NixOS/nixpkgs/pull/501773
  fixPackageDB = hfinal: hprev: {
    mkDerivation =
      args:
      let
        isExecutable = args.isExecutable or false;
        isLibrary = args.isLibrary or (!isExecutable);
      in
      hprev.mkDerivation (
        args
        // {
          postInstall =
            lib.optionalString isLibrary ''
              ghc-pkg --package-db="$packageConfDir" recache
            ''
            + (args.postInstall or "");
        }
      );
  };

  allHaskellOverlays = [
    fixPackageDB
    versionOverrides
    overlayForCustomGHC910
  ];
in
makeHaskellOverlay (lib.composeManyExtensions allHaskellOverlays)
