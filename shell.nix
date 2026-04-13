# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{ ... }:
let
  lockFile = builtins.fromJSON (builtins.readFile ./nix/flake.lock);
  flake-compat-node = lockFile.nodes.${lockFile.nodes.root.inputs.flake-compat};
  flake-compat = builtins.fetchTarball {
    inherit (flake-compat-node.locked) url;
    sha256 = flake-compat-node.locked.narHash;
  };

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
