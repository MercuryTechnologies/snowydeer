# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Verifies that a snowydeer build works correctly.
"""

from mercury_ci.actions import (
    AbstractCiActions,
    Buck2,
    ci_actions,
    is_full_mercury_repo,
)
from mercury_ci.oss import (
    UploadMode,
    cache_toolchain,
    reexec_copybara,
    setup_nix_config,
)


def default_oss_ci(upload_mode: UploadMode, buck2: Buck2):
    buck2.run("//haskell:toolchain_libs")
    cache_toolchain(upload_mode, buck2)
    buck2.test(["//..."])


def go(upload_mode: UploadMode, ci: AbstractCiActions):
    buck2 = Buck2(ci)

    if not is_full_mercury_repo(ci):
        # If we're in the full repo, the things we will check are fundamentally
        # different: we would just check snowydeer's own functionality in-situ
        # and not build everything else.
        default_oss_ci(upload_mode, buck2)

    buck2.test(["//snowydeer/...", "--exclude", "large"])


def main():
    import argparse

    ap = argparse.ArgumentParser(description="CI for snowydeer")
    ap.add_argument(
        "--copybara",
        action="store_true",
        help="Mercury-only: copybara an OSS repo then run CI from inside of it",
    )
    ap.add_argument(
        "--upload-mode",
        choices=["none", "dry-run", "ci"],
        default="dry-run",
        help="How paths should be uploaded to Nix cache",
    )
    args = ap.parse_args()

    upload_mode: UploadMode = UploadMode.from_arg(args.upload_mode)
    copybara: bool = args.copybara

    with ci_actions() as ci:
        if copybara:
            reexec_copybara(
                ci,
                "//snowydeer:copybara",
                "//snowydeer:ci",
                ["--upload-mode", upload_mode.to_arg()],
            )
        else:
            setup_nix_config(ci)
            go(upload_mode, ci)


if __name__ == "__main__":
    main()
