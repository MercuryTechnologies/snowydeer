# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{
  mkShell,
  buck2-source,
  nix,
}:
mkShell {
  nativeBuildInputs = [
    # keep-sorted start
    buck2-source
    nix
    # keep-sorted end
  ];
}
