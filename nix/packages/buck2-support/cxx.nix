# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
{
  lib,
  # See Note [GCC driver bugs] in nix/overlays/ghc.nix. We build with
  # `mercury-stdenv` (Mercury's patched gcc) but assert that the *stock*
  # `stdenv.cc` (the unpatched driver) never leaks into the output, so these
  # must stay distinct -- do not alias `stdenv` to `mercury-stdenv`.
  #
  # N.B. We don't carry these GCC patches outside Mercury since we don't have
  # 10k+ Haskell modules to link into one executable.
  stdenv,
  mercury-stdenv ? stdenv,
  makeWrapper, # TODO: `makeBinaryWrapper`?
}:
let
  isPatchedCc = mercury-stdenv.cc.outPath != stdenv.cc.outPath;
in
mercury-stdenv.mkDerivation {
  name = "buck2-cxx";
  dontUnpack = true;
  dontCheck = true;
  nativeBuildInputs = [ makeWrapper ];
  # See Note [GCC driver bugs] in nix/overlays/ghc.nix.
  disallowedRequisites = lib.optionals (isPatchedCc && !stdenv.cc.isClang) [ stdenv.cc ];
  buildPhase = ''
    function capture_env() {
        # variables to export, all variables with names beginning with one of these are exported
        local -ar vars=(
            NIX_CC_WRAPPER_TARGET_HOST_
            NIX_CFLAGS_COMPILE
            NIX_DONT_SET_RPATH
            NIX_ENFORCE_NO_NATIVE
            NIX_HARDENING_ENABLE
            NIX_IGNORE_LD_THROUGH_GCC
            NIX_LDFLAGS
            NIX_NO_SELF_RPATH
        )
        for prefix in "''${vars[@]}"; do
            for v in $( eval 'echo "''${!'"$prefix"'@}"' ); do
                echo "--set"
                echo "$v"
                echo "''${!v}"
            done
        done
    }

    # The stdenv setup adds -rpath $out/lib to NIX_LDFLAGS (the "self-rpath")
    # before buildPhase runs. capture_env bakes NIX_LDFLAGS into the cc/c++
    # wrappers, so without this strip every binary linked by this toolchain
    # inherits buck2-cxx/lib in its RUNPATH — even though that directory does
    # not exist.
    NIX_LDFLAGS=$(echo "$NIX_LDFLAGS" | sed "s|-rpath $out/lib||g")

    mkdir -p "$out/bin"

    for tool in ar nm objcopy objdump ranlib strip; do
        ln -st "$out/bin" "$NIX_CC/bin/$tool"
    done

    mapfile -t < <(capture_env)

    makeWrapper "$NIX_CC/bin/$CC" "$out/bin/cc" "''${MAPFILE[@]}"
    makeWrapper "$NIX_CC/bin/$CXX" "$out/bin/c++" "''${MAPFILE[@]}"
  '';
}
