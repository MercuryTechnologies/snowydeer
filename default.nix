# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{ ... }:
let
  lockFile = builtins.fromJSON (builtins.readFile ./nix/flake.lock);
  flake-compat-node = lockFile.nodes.${lockFile.nodes.root.inputs.flake-compat};
  # `fetchTree`, not `fetchTarball`: only the former consults substituters, via
  # `Input::fetch`
  # (https://git.lix.systems/lix-project/lix/src/e29263b638d86378b78f10a246f05ee743b117b2/lix/libfetchers/fetchers.cc#L127).
  #
  # `fetchTarball` checks the local store and otherwise goes
  # straight to GitHub's unreliable archive service.
  flake-compat = builtins.fetchTree flake-compat-node.locked;

  flake = (
    import flake-compat {
      src = ./nix;
      copySourceTreeToStore = false;
      # builtins.fetchTree checks binary caches for a copy of the path before hitting github, which helps when github is having another outage
      useBuiltinsFetchTree = true;
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
