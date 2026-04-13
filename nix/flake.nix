# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{
  description = "buck2 toolchains flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  inputs.flake-utils.url = "github:numtide/flake-utils/v1.0.0";

  # We want this for whatever unstable features buck2 is using.
  inputs.fenix = {
    url = "github:nix-community/fenix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.flake-compat = {
    url = "https://github.com/lix-project/flake-compat/archive/main.tar.gz";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      fenix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        # FIXME(jadel): necessary patches need to get ported to 9.14, then
        # switch to 9.14 here.
        compilerName = "ghc9103";
        pkgs = import nixpkgs {
          inherit system;
          overlays = import ./overlays ++ [
            fenix.overlays.default
            (final: prev: {
              mercury = prev.mercury.overrideScope (
                mfinal: mprev: {
                  inherit compilerName;
                }
              );
            })
          ];
        };
      in
      {
        packages = pkgs.mercury.buck2-toolchain;

        devShells = {
          default = pkgs.mercury.shell;
        };

        legacyPackages = {
          inherit pkgs;
          hsPkgs = pkgs.haskell.packages.${pkgs.mercury.compilerName};
        };
      }
    );
}
