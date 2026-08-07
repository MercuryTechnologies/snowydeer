# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

final: prev:
let
  inherit (prev) lib;

  ghcVer = final.mercury.compilerName;

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
    overlayForCustomGHC910
  ];
in
makeHaskellOverlay (lib.composeManyExtensions allHaskellOverlays)
