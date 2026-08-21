# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Open source-specific CI components for use with shim (for projects like
snowydeer).
"""

import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
from mercury_ci.actions import AbstractCiActions, Buck2, is_full_mercury_repo
from enum import Enum


class UploadMode(Enum):
    """
    How paths should be uploaded to cache
    """

    NO_UPLOAD = 0
    """Don't hit the upload path at all: maybe reduces build times"""
    UPLOAD_DRY_RUN = 1
    """Pretend to upload to cache, for local testing"""
    UPLOAD_CI = 2
    """Upload paths for real using the cache hook"""

    @classmethod
    def from_arg(cls, name: str) -> "UploadMode":
        match name:
            case "none":
                return cls.NO_UPLOAD
            case "dry-run":
                return cls.UPLOAD_DRY_RUN
            case "ci":
                return cls.UPLOAD_CI
            case _:
                raise ValueError(f"Unknown UploadMode: {name}")

    def to_arg(self) -> str:
        match self:
            case UploadMode.NO_UPLOAD:
                return "none"
            case UploadMode.UPLOAD_DRY_RUN:
                return "dry-run"
            case UploadMode.UPLOAD_CI:
                return "ci"


def cache_toolchain(upload_mode: UploadMode, buck2: Buck2):
    """
    Uploads toolchain to nix cache
    """
    match upload_mode:
        case UploadMode.NO_UPLOAD:
            return
        case UploadMode.UPLOAD_DRY_RUN:
            # FIXME(jadel): This whole upload methodology needs to be reworked
            # later; this target is too easy to forget to add things to e.g.
            toolchain_target = "toolchains//:all_nix_flakes"
            haskell_target = "//haskell:all"
        case UploadMode.UPLOAD_CI:
            toolchain_target = "toolchains//:all_nix_flakes[upload]"
            haskell_target = "//haskell:all[upload]"

    buck2.build([toolchain_target, haskell_target])


ENV_ALLOWLIST = {
    "PATH",
    "USER",
    "LOGNAME",
    "HOME",
    "TMPDIR",
    # systemd and various other things need this
    "XDG_RUNTIME_DIR",
}


def reexec_copybara(
    ci: AbstractCiActions,
    copybara_target: str,
    ci_run_target: str,
    args: list[str] = [],
):
    """
    Re-executes a CI workflow from within a copybara export. This allows
    testing open source CI from the context of the full Mercury repo.
    """
    if not is_full_mercury_repo(ci):
        raise ValueError("--copybara only works in the full Mercury repo")

    # The nix builds below are non-flake (-f), so they don't pick up the
    # export's nixConfig. Without this they can't substitute from cache.oss and
    # rebuild buck2 from source on every run.
    setup_nix_config(ci)

    with TemporaryDirectory("-copybara-ci") as d:
        buck2 = Buck2(ci)
        buck2.run(copybara_target, ["--folder-dir", d], capture_err=True)

        buck2_store_path = ci.run_subprocess(
            [
                "nix",
                "build",
                "--print-out-paths",
                "-f",
                str(Path(d) / "default.nix"),
                "pkgs.mercury.buck2-source",
            ],
            capture_output=True,
        ).stdout_s.strip()
        new_buck2 = buck2_store_path + "/bin/buck"
        # FIXME(jadel): delete more of PATH as if you run it from the mercury
        # repo, you get a *lot* of assorted stuff.
        filtered_env = {k: v for k, v in os.environ.items() if k in ENV_ALLOWLIST}

        print(">>> In exported repo")
        # Call ourselves, but in the new universe.
        subprocess.check_call(
            [new_buck2, "run", ci_run_target, "--", *args], cwd=d, env=filtered_env
        )


NIX_DATA_HOME = (
    Path(os.environ.get("XDG_DATA_HOME", Path("~/.local/share").expanduser())) / "nix"
)


def trust_nix_config(adds: dict[str, str]):
    """
    Adds trust entries for nixConfig entries so that the flake applies the
    substituter settings correctly and doesn't build from source.
    """
    trusted_settings_json = NIX_DATA_HOME / "trusted-settings.json"
    NIX_DATA_HOME.mkdir(parents=True, exist_ok=True)
    new_filename = trusted_settings_json.with_suffix(".new")

    try:
        with trusted_settings_json.open("r") as h:
            content = json.load(h)
    except FileNotFoundError:
        content = {}

    for k, v in adds.items():
        content[k] = content.get(k, {}) | {v: True}

    with new_filename.open("w") as h2:
        json.dump(content, h2)

    new_filename.rename(trusted_settings_json)


def add_nix_config(adds: dict[str, str], existing: str) -> str:
    nix_config_adds = adds.copy()
    lines = existing.split("\n")
    new_lines = []
    for line in lines:
        if line.startswith("#") or line.strip() == "":
            continue

        (setting_name_, _, setting_value_) = line.partition("=")
        setting_name = setting_name_.rstrip()
        setting_value = setting_value_.lstrip()
        if setting_name in nix_config_adds:
            value = nix_config_adds.pop(setting_name)
            setting_value += f" {value}"

        new_lines.append(f"{setting_name} = {setting_value}")

    # Any remaining items get added directly
    for k, v in nix_config_adds.items():
        new_lines.append(f"{k} = {v}")

    return "\n".join(new_lines)


def setup_nix_config(ci: AbstractCiActions):
    # XXX(jadel): this is all quite nasty and primarily only actually necessary if
    # you're using it locally, since most of this is configured on the CI runners
    # globally.
    NIX_CONFIG_ADDS = {
        "extra-substituters": "https://cache.oss.mercury.com",
        "extra-trusted-public-keys": "cache.oss.mercury.com-1:COfsgEgHMrBhMvGoLWuNH5RDgub3/MT32n8kK50m2dc=",
    }

    os.environ["NIX_CONFIG"] = add_nix_config(
        NIX_CONFIG_ADDS, os.environ.get("NIX_CONFIG", "")
    )
    ci.log("NIX_CONFIG:\n" + os.environ["NIX_CONFIG"])
    # Ensure that the flake configuration is trusted. This is kind of nasty and
    # we should probably instead leak NIX_CONFIG into the Buck2 build, but
    # doing this makes the native flake stuff work properly.
    trust_nix_config(NIX_CONFIG_ADDS)
