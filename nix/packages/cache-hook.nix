# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# FIXME(jadel): this whole thing should be rewritten to have a more reasonable
# architecture: don't necessarily try to upload literally everything to cache
# (as some of our stuff is designed), only upload when we build something.
# Also don't hardcode where the signing key is.
#
# The replacement should:
# - not block builds on uploading to cache
#   - but *do* block at the end of the `nix build` command itself so that any
#     dependent Buck2 remote execution actions have the paths exist in snix-store
# - not run the upload itself as root invoked by the nix-daemon (i.e. move it
#   out of the hot path of builds)
#
# One candidate architecture for this would look something like a daemon
# which receives post-build-hook events on the machine, then a way to listen to
# those build messages and drive async uploads on the consuming side (as
# regular user, rather than root).
#
# Another reasonable architecture for this would be to parse the
# `internal-json` logs from Lix and wrap the Lix executable itself; this is
# approximately what `nix-output-monitor` does (though instances may need to
# cooperate to ensure uploads happen for concurrent builds that depend on the
# same store path).

{
  stdenv,
  lib,
  nix,
  writeShellApplication,
}:
{
  destination ? "file:/tmp/cache",
  params ? { },
  # See: https://git.lix.systems/lix-project/lix/src/commit/ca89e431a31527a014bfd0d529da2a8099027a5f/releng/environment.py#L11-L20
  s3Params ? {
    want-mass-query = "true";
    write-nar-listing = "true";
    ls-compression = "zstd";
    narinfo-compression = "zstd";
    compression = "zstd";
    parallel-compression = "true";
  },
  secretKey ? null,
}:
let
  params' =
    {
      # Use a `secret-key` for signing store paths.
      #
      # If a `secret-key` is set, it's always used.
      # See: https://git.lix.systems/lix-project/lix/src/commit/7575db522e9008685c4009423398f6900a16bcce/src/libstore/binary-cache-store.cc#L29-L30
      # See: https://git.lix.systems/lix-project/lix/src/commit/7575db522e9008685c4009423398f6900a16bcce/src/libstore/binary-cache-store.cc#L258-L261
      secret-key =
        if secretKey != null then
          secretKey
        else if stdenv.isDarwin then
          "/opt/mercury/secrets/nix-cache-signing-key"
        else
          "/secrets/nix-cache-signing-key";
    }
    // lib.optionalAttrs (lib.hasPrefix "s3://" destination) s3Params
    // params;
  encodedParams = lib.concatStringsSep "&" (
    lib.mapAttrsToList (key: value: "${key}=${lib.strings.escapeURL value}") params'
  );
  destination' = "${destination}?${encodedParams}";
in
writeShellApplication {
  name = "cache-hook";

  runtimeInputs = [ nix ];

  text = ''
    if [ "$#" -eq 1 ]; then
      OUT_PATHS=$(< "$1")
    fi

    echo "$OUT_PATHS" | \
      xargs --no-run-if-empty \
      nix copy \
        --to ${lib.escapeShellArg destination'}
  '';
}
