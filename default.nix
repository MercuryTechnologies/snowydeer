# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{ ... }:
let
  lockFile = builtins.fromJSON (builtins.readFile ./nix/flake.lock);
  flake-compat-node = lockFile.nodes.${lockFile.nodes.root.inputs.flake-compat};
  flake-compat = builtins.fetchTarball {
    url = "https://github.com/${flake-compat-node.locked.owner}/${flake-compat-node.locked.repo}/archive/${flake-compat-node.locked.rev}.tar.gz";
    sha256 = flake-compat-node.locked.narHash;
  };

  flake = (
    import flake-compat {
      src = ./nix;
      copySourceTreeToStore = false;
    }
  );

  flakeOutputs = flake.defaultNix;
in
{
  inherit (flakeOutputs.legacyPackages.${builtins.currentSystem})
    pkgs
    hsPkgs
    ;
}
