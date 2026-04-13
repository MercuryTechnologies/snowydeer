# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{ }:
# Hack from https://git.lix.systems/lix-project/lix/issues/402#issuecomment-5889
path:
builtins.appendContext path {
  ${path} = {
    path = true;
  };
}
