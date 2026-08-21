# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{ ... }:
let
  lockFile = builtins.fromJSON (builtins.readFile ./flake.lock);
  flake-compat-node = lockFile.nodes.${lockFile.nodes.root.inputs.flake-compat};
  # `fetchTree`, not `fetchTarball`: see ../default.nix.
  flake-compat = builtins.fetchTree flake-compat-node.locked;

  flake = (
    import flake-compat {
      src = ./.;
      copySourceTreeToStore = false;
      # builtins.fetchTree checks binary caches for a copy of the path before hitting github, which helps when github is having another outage
      useBuiltinsFetchTree = true;
    }
  );

  flakeOutputs = flake.defaultNix;
in
# The buck2 toolchain flake
flakeOutputs.packages.${builtins.currentSystem}
// {
  # primarily for debugging
  inherit (flakeOutputs.legacyPackages.${builtins.currentSystem}) pkgs;
}
