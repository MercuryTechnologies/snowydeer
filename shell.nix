# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{ ... }:
let
  lockFile = builtins.fromJSON (builtins.readFile ./nix/flake.lock);
  flake-compat-node = lockFile.nodes.${lockFile.nodes.root.inputs.flake-compat};
  # `fetchTree`, not `fetchTarball`: see ./default.nix.
  flake-compat = builtins.fetchTree flake-compat-node.locked;

  flake = (
    import flake-compat {
      src = ./nix;
      copySourceTreeToStore = false;
    }
  );

  devShells = flake.shellNix.devShells.${builtins.currentSystem};
in
devShells.default.overrideAttrs (prev: {
  passthru = (prev.passthru or { }) // devShells;
})
