# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Shim for Haskell tests in OSS.
"""

load("//haskell:mercury_haskell.bzl", "mercury_haskell_binary")

def local_packages_spec(name, *args, env: dict[str, str] = {}, target_compatible_with = [], labels: list[str] = [], **kwargs):
    """
    Creates a spec run for a local-packages package that just runs a
    haskell_binary of an hspec test with no args.
    """
    bin_name = name + ".binary"
    mercury_haskell_binary(
        bin_name,
        linker_flags = ["-threaded"],
        target_compatible_with = target_compatible_with,
        labels = labels,
        *args,
        **kwargs
    )
    native.sh_test(
        name = name,
        test = ":" + bin_name,
        env = env,
        labels = labels,
        target_compatible_with = target_compatible_with,
    )
