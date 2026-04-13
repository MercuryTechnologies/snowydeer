# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# File shared with the OSS toolchain which contains all our GHC patches.

final: [
  # Show installed versions when configuring fails
  #
  # This greatly improves error messages when dependencies are incorrect in
  # Nix builds of Haskell packages.
  (final.fetchpatch {
    url = "https://github.com/haskell/cabal/pull/10406/commits/2a0662c6514f77a296138e995ed24230aef21825.diff";
    extraPrefix = "libraries/Cabal/";
    stripLen = 1;
    hash = "sha256-aompz2sAFuhzq+vh5Zp8p0ZDgXb6gqFrmpsWtcWGnfA=";
  })

  # NOTE: In the "In HEAD" comment, "Yes" means the patch has been included as of GHC 9.13.20241128.
  # "Not merged yet" means that the patch is in the process of MR, but not yet merged.
  # and "No but not needed" means that the patch is only relevant for GHC 9.10 backport.
  # We note the checked date in the parentheses for the merge commit.

  # rts: free error message before returning
  # In HEAD: Yes. (2024-11-28)
  # rts: free error message before returning
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/66c914d6bd32d5d97983cca1324bf72977d025c8.diff";
    hash = "sha256-kdEyuvCjWzH7/n1gLucbr5zLTjIIVsaHADVpb/gW0p4=";
  })

  # linker: Avoid linear search when looking up Haskell symbols via dlsym
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/5583003b149d8397e942c7d93fe7806848e88b03.diff";
    excludes = [ "testsuite/**" ];
    hash = "sha256-x7SHXebWSY0lAsYarHlt6n6iYKzUF+NcS8358WokyNg=";
  })

  # rts: Make addDLL a wrapper around loadNativeObj
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/9e24947f32a4f503a69a2d038d5b09efac357780.diff";
    excludes = [ "testsuite/**" ];
    hash = "sha256-CsxCwlkd2suGSRaurDr+G6EPVFcBxF+ION62O11jX9E=";
  })

  # Use symbol cache in internal interpreter too
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/82df3315531b3393c37cb96d4138264f00493e52.diff";
    hash = "sha256-wrE5UgHxO8g7/JEGDlFRGpaI/atruAb7r+ndVoVOer0=";
  })

  # testsuite: Add test for lookupSymbolInNativeObj
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/2275dad531fa61ca462592aebbc8d18581c219e4.diff";
    hash = "sha256-W1oIEnMLvTBYA8Om4zm3K8ePZ25f9fpqXE8VRpsNqR0=";
  })

  # Don't store a GlobalRdrEnv in `mi_globals` for GHCi.
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/37f0cf5c420d1354bf0b00efebfc6a21ccdb7ed1.diff";
    hash = "sha256-4aRRqSkgb1fdqw8k28ryxcOU39IvPKv1hRDvgCHhAQo=";
  })

  # driver: add -dep-json -opt-json flags to ghc -M
  # In HEAD: Not yet.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/55cf74b393fbe543dddf853fc5143c39ba70e836.diff";
    hash = "sha256-8h3UmsoZB1YBaGJ/ffqT7GT/QaWK2/LmSNNEuhe8xPs=";
  })

  # Parallelize getRootSummary computations in dep analysis downsweep
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/d8900f977c592a4bb6ee64ab763fcd55b84df31e.diff";
    hash = "sha256-8gMmZNEvIv4ytI0YLnQ8UebS+torLlvQ4IFAnhCmVIw=";
  })

  # Typecheck corebindings lazily during bytecode generation
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/c9cf4bb9236265a6942c8824fc391ded33fce366.diff";
    hash = "sha256-og3rYSE6me6ehNOvwWU65kx0mLSb/PPu6l/slTzbro4=";
  })

  # Linker: some refactoring to prepare for #24886
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/48d57f53af5c8981e530f54b09486792ad59225e.diff";
    hash = "sha256-1F66/XnbsS/tKuaFcC6xk9KS5Hidjk/8OUHTogC3DNs=";
  })

  # compiler: Store ForeignStubs and foreign C files in interfaces
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/f4ec5e4cc2b80a6a785c6e4df57abd9a46ede030.diff";
    hash = "sha256-MxwMRehLrO+RqDHvUr3hEpWsAqnkVX37S13GWOVx+3c=";
  })

  # Build foreign objects for TH with interpreter's way when loading from iface
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/d154ad542434c80c50284e7904748d2f7cc89d64.diff";
    hash = "sha256-4tdT1+ErQm6w0VxUBvbQx4sFnaH0XYhsV5290qYfd1I=";
  })

  # Link bytecode from interface-stored core bindings in oneshot mode
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/2d7458a88dc4659812da748c92f75dfa1b7714ef.diff";
    hash = "sha256-Xit7AJNMZ5zNIoqmw1QI7m+Uf3BOY0bfsomCIIVGYW8=";
  })

  # driver: fix foreign stub handling logic in hscParsedDecls
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/b8395b900d40f89ed9605f2c0753d6eced9da095.diff";
    hash = "sha256-VrlKHDe5PQcwV3zuJn0hKkZwzE/DC2d2b4mP18q6cFo=";
  })

  # Link interface bytecode from package DBs if possible
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/d32e7998d6fdfbac4704956f232fddc5e384a2d6.diff";
    hash = "sha256-ZkLe+dWJmZVAFQzy+8DP/w+fM/EGZKjXHXuGS9Hg+sM=";
  })

  # compiler: implement --show-iface-abi-hash major mode
  # In HEAD: Not yet.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/b896f60649d2260ca77ddb053e596cefbda386c6.diff";
    hash = "sha256-+l1z7iHaoVcJVKRkJxNHAG5j9nwZUp/aXvM/cY0ftqI=";
  })

  # set extra_decls = Nothing in interpreter after interface generation
  # In HEAD: Not yet.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/914716ed1f82ba850e572d54525ec5d3190466d5.diff";
    hash = "sha256-kv4valwzeZQuPg3TCLW7WMMb0eIlVU1W4A1Gcsi2eqs=";
  })

  # rts: Tighten up invariants of PACK
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/c80f691a3a6a95a41e370840c7b853d6f0df1e5c.diff";
    hash = "sha256-oTdpxfgTxbDIDTpO9szJmwc2Hu8mVWIoO+0N2iHoY7I=";
  })

  # StgToByteCode: Don't assume that data con workers are nullary
  # In HEAD:
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/f5972fc58b63262547299d544be459106fc327fc.diff";
    hash = "sha256-1QNJev7I1bOvHww2ZAdz8A5wkUkEMtqVdeHmTSYCTnw=";
  })

  # driver: fix hpc undefined symbol issue in TH with -fprefer-byte-code
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/cca12179eac531de39ff141354eac382f94209ef.diff";
    excludes = [ "testsuite/**" ];
    hash = "sha256-N4mXVDRc59B3mByLD0MvgyKoUQQdOAfhfgOWF2joO9E=";
  })

  # ghc-internal: No trailing whitespace in exceptions
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/7f86a1cc183d3d4046df43b3fbf0438ae01849fe.diff";
    hash = "sha256-D7ZDZBnGHD0H9jjUnZYSG7P6H1IS2xp92ykmuWwXamU=";
  })

  # refactor quadratic search in warnMissingHomeModules
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/efdf74e24d3bb366e56e94873bb55c851744aa7a.diff";
    hash = "sha256-1feiLnTj10rOw2tJXVBM4UKXFxsTN3GZ3jd7g7KUdpk=";
  })

  # Improve reachability queries on ModuleGraph
  # In HEAD: Yes. (2024-11-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/f61ff10253af927f7fb7673ff22698a7d8a75b8d.diff";
    hash = "sha256-gPOpr/h3oDTRNznVc6CxzjZmC1DVYmFncSAD9KjitbE=";
  })

  # similarize the parallel downsweep to GHC HEAD version.
  # In HEAD: No, but not needed.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/e475d6b94eee34998c394f5d418d3718791f427b.diff";
    hash = "sha256-PEIQUziOD9ich1xu5av4c+Aq2PtWhD6w6NPolYYbo5c=";
  })

  # Use deterministic names for temporary files
  # In HEAD: No, but not needed.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/a0bf17f1745ebefbe8aadc10d4f0efc3952d211f.diff";
    hash = "sha256-BTYwWrAqK/zb+R10rKyoOY2s+Pi0CumSBL9SF4YnBGw=";
  })

  # monotonic FinderCache. missed part from parallel downsweep latest GHC HEAD patch
  # In HEAD: No, but not needed.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/5029498acef191d1503eae14c0d8f3b59d9134ce.diff";
    hash = "sha256-lJJXPEGPp9HaDzJh0Z30xfYcdKvBbUVVMbwR0Lopy6M=";
  })

  # SpecConstr: Introduce a separate argument limit for forced specs.
  # In HEAD: Yes. (2025-02-28)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/e4fc5e2c98c9401ce83606372a2bd1cf164d2a70.diff";
    hash = "sha256-4G2AcwU1pQJdoaQU+3m+F345+nLGxsAbnQk6Gi9g+U0=";
    excludes = [ "testsuite/**" ];
  })

  # No in-memory resident mi_extra_decls in compilation. They are transiently
  # loaded and removed after byte-code generation.
  # In HEAD: No, but not needed.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/78de1f66835dc3bf0b9b658396f07bdfb0627a9b.diff";
    hash = "sha256-nXPMhfBYeV/uJySj/wDAB6csjeKKVSlJ/qnoYl4+7LE=";
  })

  # Use OsPath in PkgDbRef and UnitDatabase, not FilePath
  # In HEAD: No. Not clear for upstreaming need. TODO: Clarify
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/312e346f813bedeaae49fd8c97913a9b7dcebdd0.diff";
    hash = "sha256-IPtO6RFFfCrNm6A0MsI1mQ06gAmE15YknWl0bohbm/A=";
    excludes = [ "testsuite/**" ];
  })

  # Various downsweep perf tweaks
  # In HEAD: No. Not clear for upstreaming need. TODO: Clarify
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/529ff81c6c1b8306a2c2a8d948b6e24073c3ee31.diff";
    hash = "sha256-DCit6lwlGx3td4MrbLIpNY6dTjEiLKTHFAUNM18tPPs=";
    excludes = [ "testsuite/**" ];
  })

  # Abstract out parts of mkUnitState into a handler type
  # In HEAD:
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/3079ecfc10d3ad94ba3bad6b6089e9991fbd0017.diff";
    hash = "sha256-FlG9sbqxcnojkPoSoKb5ROwPYrfTL6QF4dTwOXAHUlk=";
    excludes = [ "testsuite/**" ];
  })

  # Abstract out module provider queries into a handler type
  # In HEAD:
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/b26479272da6cc9a23bc13679ca9adf01b9269cf.diff";
    hash = "sha256-ULEw9S9jLLzUgisySJy/GiTe7bJIh8qYoGEEWKsgCK4=";
    excludes = [ "testsuite/**" ];
  })

  # Use unit index for name printing
  # In HEAD:
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/c53dc5ecc71f14b4a0220f7bb88195512a7e7055.diff";
    hash = "sha256-VGRawZHF2ix/m7wLr3iBHFEp+ZgKHB3DjrFnFzm1uoU=";
    excludes = [ "testsuite/**" ];
  })

  # Bunch of backports
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/2aa607e59d78efa304c87381cb41aa6c1c77e635.diff";
    hash = "sha256-SHN7WBJN3ULpDj8B+KQ+2CdYG5bqvAX4peReXoSiCiA=";
    excludes = [ "testsuite/**" ];
  })

  # Division by constants optimization
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/c774692a4d9e46140d6416a34e64a10688ce0c3c.diff";
    hash = "sha256-Pp04yxyYzRNwCzkBOrohd+W8Sv9U3HZ7xqEMZL/GLso=";
    excludes = [ "testsuite/tests/numeric/should_run/*" ];
  })

  # determinism: Sampling uniques in the CG
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/098537f51d7f968bdd3e1214c63a5665350fa57f.diff";
    hash = "sha256-VYvleCfdENo1NYW4aQznm4IxBHQ6Bn/WmFKi0isZ9P4=";
    excludes = [ "testsuite/**" ];
  })

  # determinism: DCmmGroup vs CmmGroup
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/f41499d67c3ecdbdd435d42c42a47ae131880ffd.diff";
    hash = "sha256-h1xUZ9j1R3Dnyunp3Y5Y7lfwlJzIfoVsTRBgMFUVOTw=";
    excludes = [ "testsuite/**" ];
  })

  # determinism: Cmm unique renaming pass
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/c50d3b90e45351d27534bf85f8814ff9b02b13f1.diff";
    hash = "sha256-s+JqbjtfBnoGCuGX0vhtffCMf/3ibzrFKhFdvkxD7aI=";
    excludes = [ "testsuite/**" ];
  })

  # Revert "Division by constants optimization"
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/19105e343a00e1a89d5860ef619ec0aaddb14174.diff";
    hash = "sha256-YBwNkIVud1bE/ymGh4Dxm3l7Sk/8bm3xgzHzh9IVRNM=";
    excludes = [ "testsuite/**" ];
  })

  # hi: Stable sort avails
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/ece97f308229d4cdc1e90a91af35879634454b20.diff";
    hash = "sha256-snoxXNkP847J1cjEerZOBP3/PDx0HHkm5HySFQ35JHU=";
    excludes = [ "testsuite/**" ];
  })

  # determinism: Interface re-export list det
  # In HEAD: Yes.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/0e70a06441761beee43bfe76ae09e98478d84e23.diff";
    hash = "sha256-bMWBlnUBnZ1p6H5yoBMulFLTr9Byu9QDDSONfMPytlE=";
    excludes = [ "testsuite/**" ];
  })

  # WIP: determinism: sort dependent file
  # In HEAD: No.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/68d0026204d2cfce52423e975d932aa5892c7702.diff";
    hash = "sha256-tL54c4P/bYjd1x9KQrtZbisBUrVqmbK/PshQJG8+UYo=";
    excludes = [ "testsuite/**" ];
  })

  # determinism: Use deterministic map for Strings in TyLitMap
  # In HEAD: Not yet.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/6c025f47be4309180724fbcfbe3b2026eaa749c0.diff";
    hash = "sha256-CBI9Oft2Cb9pOabpPxGFIsEpLXPBLNSCiDQ66Cw18Ug=";
    excludes = [ "testsuite/**" ];
  })

  # determinism: Use a stable sort in WithHsDocIdentifiers binary instance
  # In HEAD: Not yet.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/5f90399b21bfd8daa6151eded616449036138427.diff";
    hash = "sha256-Ys2Vp/UdbzJJBGY1YXn6wHUBypOPEm1sqO16R5QiwW0=";
    excludes = [ "testsuite/**" ];
  })

  # Raise headerpad from 8000 to 16000
  # In HEAD: No.
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/fd935b1e70c850d12e54b06be14ab6f8982a1f5b.diff";
    hash = "sha256-PnBa/ooQf1NnNJSohLAixQ2uE3uQYYUZ/ChTF2o2jlo=";
    excludes = [ "testsuite/**" ];
  })

  # Report all missing modules with -M
  # In HEAD: Yes. (2025-11-19)
  (final.fetchpatch {
    url = "https://github.com/MercuryTechnologies/ghc/commit/8bbcd7c541e759b21d3d0e343eb3a3494e7d4fb9.diff";
    hash = "sha256-I8UmdPCIwU7LHYf+IQtqnS70HjXLpJXHIhYIfea/5YY=";
    excludes = [ "testsuite/**" ];
  })

  # Avoid expensive computation for debug logging in `mergeDatabases` when log level is low
  # In HEAD: Not yet but approved.
  (final.fetchpatch {
    #wavewave/20260227-mergeDatabase-fix
    url = "https://github.com/MercuryTechnologies/ghc/commit/8f61a41625dfa6d6617754b1ba3f8e787c96b6fc.diff";
    hash = "sha256-gy8PWutrBhe3Agcz7K/+DGEl6CvLpmzmmyD1jb9vnx8=";
    excludes = [ "testsuite/**" ];
  })

  ./haddock-ghc9101-mem-improv-backport.patch

  ./haddock-ghc9101-det-iface-re-export.patch
]
