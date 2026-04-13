# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# Sadly, we have buck2-required patches, but we would ideally like to just use upstream ghc.
final: prev:

let
  inherit (prev.haskell.lib.compose) dontCheck;

  mkGhcSrc =
    {
      version,
      hash,
    }:
    final.fetchurl {
      url = "https://downloads.haskell.org/ghc/${version}/ghc-${version}-src.tar.xz";
      inherit hash;
    };

  # FIXME(jadel): this is horrible. we don't want to go do a very complex
  # backporting process to get onto 9.10.3 OR 9.14 for OSS first, so we swap
  # the version from underneath it.
  ghc9101Src = mkGhcSrc {
    version = "9.10.1";
    hash = "sha256-vzhqMC1O4FR5H/1RdIkA8V1xdg/RmRV5ItEgzB+J4vc=";
  };

  mkGhc =
    {
      compiler,
      src,
      patches,
      bootPkgs,
      ghcFlavour ? null,
    }:
    (compiler.override (
      {
        # Note: GHC 9.10.1 uses GHC 9.6.3 as boot compiler and unfortunately,
        # in nixpkgs, haskell.packages.ghc963 is used for bootPkgs. That means
        # our haskell package overlay is unnecessarily applied in compiling GHC.
        # In particular, this caused an issue with GHC 9.10.1 used for Buck2 since
        # local-packages are not included in nix cell intentionally.
        # The best way is just to specify proper minimal bootPkgs for compiler
        # compilation, so we pass the bootPkgs arguement.
        bootPkgs = if bootPkgs == null then compiler.bootPkgs else bootPkgs;

        enableDocs = false;

        # The GHC 9.6 builder in nixpkgs first builds hadrian with the
        # source tree provided here and then uses the built hadrian to
        # build the rest of GHC. We need to make sure our patches get
        # included in this `src`, then, rather than modifying the tree in
        # the `patchPhase` or `postPatch` of the outer builder.
        ghcSrc =
          (final.applyPatches {
            inherit src patches;
          }).overrideAttrs
            (drv: {
              # After patching the GHC, we need to regenerate compiler/GHC/Cmm/Parser.hs
              # for which a pre-generated version was included in the GHC source
              # distribution. So here the generated file is deleted and the original
              # source is restored for a patch to be applied.
              prePatch = ''
                echo "Recreating GHC.Cmm.Parser.y"
                mv compiler/GHC/Cmm/Parser.y.source compiler/GHC/Cmm/Parser.y
                rm compiler/GHC/Cmm/Parser.hs

                echo "Doing evil to the version"
                substituteInPlace configure.ac --replace-fail 9.10.1 9.10.3

                # Don't put three trivial patches in the build graph for this.
                # https://gitlab.haskell.org/ghc/ghc/-/commit/70f7741acd9d50a6cc07553aeaae600afe4a72b8
                # https://gitlab.haskell.org/ghc/ghc/-/commit/f983a00ffc97b779eb52b10e69e254ec107f8311
                # https://gitlab.haskell.org/ghc/ghc/-/commit/7596675e470699f6184e13c08b268972028bc868
                substituteInPlace utils/hp2ps/Utilities.c \
                  --replace-fail 'extern void* malloc();' "" --replace-fail 'extern void *realloc();' ""
                sed -i '2i #include <stdlib.h>' utils/hp2ps/Utilities.c
              '';
            });
      }
      // prev.lib.optionalAttrs (ghcFlavour != null) {
        # Theoretically `prev.ghcFlavour` should work here, but the attribute
        # is missing for some reason. You can find the value in the Nix repl,
        # though:
        #
        #     $ nix repl --file .
        #     nix-repl> pkgs.haskell.compiler.ghc9103.hadrianFlags
        #     [
        #       "--flavour=release+split_sections"
        #       "--bignum=gmp"
        #       "--docs=no-sphinx-pdfs"
        #     ]
        #
        # See: https://github.com/NixOS/nixpkgs/blob/11e0819a5c2ff8b6e1a060f9b34c2516358930f0/pkgs/development/compilers/ghc/common-hadrian.nix#L94-L115
        inherit ghcFlavour;
      }
    ));

  # to avoid conflicts, we use GHC 9.6.7 as bootstrap compiler of GHC 9.10.1.
  ghc9103BootPkgs = prev.haskell.packages.ghc967.override (prev: {
    overrides = prev.lib.composeExtensions (prev.overrides or (_: _: { })) (
      hfinal: hprev: {
        # The upstream GHC tarball includes the generated parser
        # (`compiler/GHC/Cmm/Parser.hs`), but we've patched the source
        # (`compiler/GHC/Cmm/Parser.y.source`), so we need to regenerate
        # the `.hs`, which requires `happy`.
        #
        # The Nixpkgs Haskell package set ships a version of `happy` that
        # is not able to build GHC 9.10:
        #
        #     checking for version of happy... 2.0.2
        #     configure: error: Happy version 1.20 or earlier is required to compile GHC.
        #
        # The upstream build doesn't notice this because it does not need
        # to generate the `.hs` file.
        #
        # See: https://gitlab.haskell.org/ghc/ghc/-/blob/6d779c0fab30c39475aef50d39064ed67ce839d7/m4/fptools_happy.m4#L25-L31
        # Test suite takes forever
        happy = dontCheck hprev.happy_1_20_1_1;
        # Tests are very slow to build due to no concurrency
        alex = dontCheck hprev.alex;
      }
    );
  });

  # Copypasta from the mwb version. The notable ones are the various CLI
  # changes which are required for buck2-haskell.
  ghc910Patches = import ./ghc/patches/9.10 final;
in
{
  haskell = prev.haskell // {
    compiler = prev.haskell.compiler // {
      ghc9103 = mkGhc {
        compiler = prev.haskell.compiler.ghc9103;
        src = ghc9101Src;
        patches = ghc910Patches;
        bootPkgs = ghc9103BootPkgs;
      };
    };
  };
}
