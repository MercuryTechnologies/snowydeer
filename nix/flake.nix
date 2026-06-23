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
    url = "github:lix-project/flake-compat";
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
        stockCompilerName = "ghc9103";
        pkgs = import nixpkgs {
          inherit system;
          overlays = import ./overlays ++ [
            fenix.overlays.default
            (final: prev: {
              mercury = prev.mercury.overrideScope (
                mfinal: mprev: {
                  compilerName = "${stockCompilerName}-mercury";
                  inherit stockCompilerName;
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

  nixConfig.extra-substituters = [ "https://cache.oss.mercury.com" ];
  nixConfig.extra-trusted-public-keys = [
    "cache.oss.mercury.com-1:COfsgEgHMrBhMvGoLWuNH5RDgub3/MT32n8kK50m2dc="
  ];
}
