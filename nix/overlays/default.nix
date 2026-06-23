# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

let
  packagesDir = final: prev: {
    mercury = prev.lib.makeScope prev.newScope (
      self:
      (prev.lib.packagesFromDirectoryRecursive {
        inherit (self) callPackage;
        directory = ../packages;
      })
    );
  };

  # don't want to put this in pkgs.mercury, so we have to do special stuff for it
  libAdditions = final: prev: {
    lib = prev.lib // {
      fabricateStringContext = final.callPackage ../lib/fabricateStringContext.nix { };
    };
  };

  lix = final: prev: {
    nix = final.lixPackageSets.latest.lix;
  };
in
[
  libAdditions
  packagesDir
  lix
  (import ./ghc.nix)
  (import ./haskell.nix)
]
