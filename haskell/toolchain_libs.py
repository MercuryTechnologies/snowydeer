# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Updates toolchains/libs.bzl, nix/buck2-toolchain/ghc-toolchain-libraries.nix to
match the requested nix-sourced Haskell dependencies of targets.
"""

import json
import subprocess
from pathlib import Path


def main():
    libs = subprocess.check_output(
        ["buck", "bxl", "//haskell/get_toolchain_libs.bxl:libs"]
    )
    toolchain_libs = json.loads(libs)

    # write toolchains/libs.bzl

    libs = ",\n    ".join(f'"{lib}"' for lib in sorted(toolchain_libs))

    Path("toolchains/libs.bzl").write_text(
        f"""\
# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

\"""
THIS FILE IS AUTO-GENERATED -- DO NOT EDIT --

Note: regenerate with `buck run //haskell:toolchain_libs`
\"""

toolchain_libraries = [
    {libs},
]
"""
    )

    # write toolchains/nix/buck2-toolchain/ghc-toolchain-libraries.nix
    libs = "\n  ".join(f'"{lib}"' for lib in sorted(toolchain_libs))

    Path("nix/packages/buck2-toolchain/ghc-toolchain-libraries.nix").write_text(
        f"""\
# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# THIS FILE IS AUTO-GENERATED -- DO NOT EDIT --
#
# Note: regenerate with `buck run //haskell:toolchain_libs`

[
  {libs}
]
"""
    )


if __name__ == "__main__":
    main()
