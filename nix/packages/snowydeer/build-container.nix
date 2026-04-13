# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# Used by //snowydeer/container
{
  lib,
  dockerTools,
  tini,
  cacert,
  bash,
  coreutils,
  curl,
}:
{ buildPlanJSON }:
let
  # Resolve all Nix store references in the build plan.
  visit =
    value:
    if builtins.typeOf value == "string" then
      if lib.hasPrefix "/nix/store" value then lib.fabricateStringContext value else value
    else if builtins.typeOf value == "set" then
      lib.mapAttrsRecursive (_path: v: visit v) value
    else if builtins.typeOf value == "list" then
      map visit value
    else
      value;

  baseContents = [
    dockerTools.usrBinEnv
    bash
    coreutils
    curl
    # So that TLS works
    cacert
  ];

  parsed = builtins.fromJSON buildPlanJSON;
  plan = visit parsed;
in
dockerTools.streamLayeredImage {
  name = plan.name;
  contents = baseContents ++ plan.contents;

  maxLayers = 127;

  layeringPipeline = [
    # yoink out the base image from all user contents, since that's already got
    # a fair bit of stuff in it.
    [
      "subcomponent_out"
      (baseContents ++ [ tini ])
    ]
  ] ++ plan.layeringPipeline;

  # https://specs.opencontainers.org/image-spec/config/
  config = {
    Cmd = plan.cmd;
    Entrypoint = [
      (lib.getExe tini)
      "--"
    ];
    Env = lib.mapAttrsToList (k: v: "${k}=${v}") plan.env;
    # goofy golang schema, we can have reasonable types internally
    ExposedPorts = lib.genAttrs plan.ports (_: { });

    Labels = plan.metadata;
  };
}
