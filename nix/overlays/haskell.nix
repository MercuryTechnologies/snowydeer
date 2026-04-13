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
  ];
in
makeHaskellOverlay (lib.composeManyExtensions allHaskellOverlays)
