# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# Used by //snowydeer/container
{
  lib,
  stdenv,
  dockerTools,
  tini,
  cacert,
  bash,
  iproute2,
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
    # So that TLS works
    dockerTools.caCertificates
    bash
    coreutils
    curl
    # We used to have iproute2 here, but it adds a symlink at /sbin which
    # breaks base images, and the only reason it was here was for debugging.
  ];

  baseEnv = {
    # If you use libc locale support such as by misuse of iconv, we need to
    # make sure we're on a UTF-8 locale to not corrupt non-ASCII data. Haskell
    # loves to obey system locale!! And the default of "C" counterintuitively
    # stands for "the C programming language was a mistake", rather than
    # "corrupt my data uwu" even though that's what it does, instead of passing
    # your data directly through.
    #
    # All my besties love saying "hPutChar: invalid argument (invalid character)"
    LANG = "C.UTF-8";
  };

  parsed = builtins.fromJSON buildPlanJSON;
  plan = visit parsed;

  # Optional base image from snowydeer_base_image. null for ordinary
  # first-party images; present for third-party base images.
  base = plan.baseImage or null;
  fromImage =
    if base == null then
      null
    else
      assert base.system == stdenv.hostPlatform.system;
      dockerTools.pullImage {
        imageName = base.imageName;
        imageDigest = base.imageDigest;
        hash = base.hash; # SRI nar hash; pullImage accepts `hash`
        # base.system is always the build-host system; use the pre-elaborated
        # stdenv.hostPlatform rather than re-elaborating the string.
        os = stdenv.hostPlatform.go.GOOS;
        arch = stdenv.hostPlatform.go.GOARCH;
        finalImageName = base.imageName;
        # Must match nix-prefetch-docker's --final-image-tag so the nar hash round-trips.
        finalImageTag = "pinned";
      };
in
dockerTools.streamLayeredImage {
  name = plan.name;
  contents = baseContents ++ plan.contents;
  inherit fromImage;

  maxLayers = 127;

  # Nothing in `contents` can provide /tmp (the nix store normalizes away the
  # sticky bit), and OCI runtimes don't create it, so programs that need a
  # temp dir (e.g. secret-agent rendering file-type secret specs) fail with
  # ENOENT without it. Same approach as the nixpkgs dockerTools examples.
  extraCommands = ''
    mkdir -p tmp
    chmod 1777 tmp
  '';

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
    Env = lib.mapAttrsToList (k: v: "${k}=${v}") (baseEnv // plan.env);
    # goofy golang schema, we can have reasonable types internally
    ExposedPorts = lib.genAttrs plan.ports (_: { });

    Labels = plan.metadata;
  };
}
