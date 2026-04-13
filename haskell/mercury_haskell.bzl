# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Mercury's haskell rule wrappers.
"""

load("@buck2-haskell//:defs.bzl", "haskell_binary", "haskell_library")
load("//haskell:defs.bzl", "default_ghc_flags")

# FIXME(jadel): lots of semi important stuff which is not shared

def _generate_module_prefix():
    path_parts = package_name().split("/")
    module_parts = list(filter(lambda p: not p.islower(), path_parts))
    return ".".join(module_parts)

def mercury_haskell_library(
        name,
        srcs = [],
        extra_compiler_flags = [],
        prefix: str | None = None,
        allow_cache_upload = True,
        **kwargs):
    """haskell_library wrapper with Mercury-specific defaults and checks

    Args:
      srcs: List of hs srcs to forward to haskell_library and to check with hlint etc
      extra_compiler_flags: Additional compiler flags to add to default_ghc_flags
      prefix: Directory prefix to remove from module names. Not required unless
              your source directory is not called src, test or app.
    """

    if not "module_prefix" in kwargs:
        kwargs["module_prefix"] = _generate_module_prefix()

    # Check that all srcs_deps keys are present in srcs. We should move this
    # check into buck2-haskell at some point.
    if "srcs_deps" in kwargs:
        extra_srcs_deps = list(sorted(set(kwargs["srcs_deps"].keys()) - set(srcs)))
        if len(extra_srcs_deps) > 0:
            fail("'{}' has some srcs_deps entries which aren't present in srcs. Please remove them from srcs_deps: {}".format(
                name,
                extra_srcs_deps,
            ))

    haskell_library(
        name = name,
        srcs = srcs,
        compiler_flags = default_ghc_flags + extra_compiler_flags,
        strip_prefix = ["src", "test", "app"] + ([prefix] if prefix else []),
        # validate_srcs = "//haskell:check_module_names",
        # _worker = "toolchains//:persistent_worker",
        # allow_worker = select({
        #     "//constraints/worker_type[worker]": True,
        #     "DEFAULT": False,
        # }),
        allow_cache_upload = allow_cache_upload,
        **kwargs
    )

def mercury_haskell_binary(
        name,
        srcs = [],
        extra_compiler_flags = [],
        main = None,
        prefix: str | None = None,
        **kwargs):
    """haskell_binary wrapper with Mercury-specific defaults and checks

    Args:
      srcs: List of hs srcs to forward to haskell_binary and to check with hlint etc
      extra_compiler_flags: Additional compiler flags to add to default_ghc_flags
      prefix: Directory prefix to remove from module names. Not required unless
              your source directory is not called src, test or app.
    """
    if not "module_prefix" in kwargs:
        kwargs["module_prefix"] = _generate_module_prefix()

    haskell_binary(
        name = name,
        srcs = srcs,
        compiler_flags = default_ghc_flags + extra_compiler_flags,
        # _worker = "toolchains//:persistent_worker",
        # allow_worker = select({
        #     "//constraints/worker_type[worker]": True,
        #     "DEFAULT": False,
        # }),
        strip_prefix = ["src", "test", "app"] + ([prefix] if prefix else []),
        main = main,
        # validate_srcs = "//haskell:check_module_names",
        **kwargs
    )
