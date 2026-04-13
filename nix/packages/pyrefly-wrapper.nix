# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{
  writeShellApplication,
  pyrefly,
}:
writeShellApplication {
  name = "pyrefly";
  runtimeInputs = [
    pyrefly
  ];
  text = builtins.readFile ./pyrefly-wrapper.sh;
}
