# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""End-to-end coverage for BTD planning over a miniature Git/Buck repository."""

import json
import os
import shutil
import subprocess
from collections.abc import Iterator
from dataclasses import dataclass, replace
from pathlib import Path

import pytest

from mercury_ci.actions import ci_actions
from mercury_ci.btd_ci import (
    BtdCi,
    GitObjectId,
    PlatformPlan,
    RevisionPair,
)
from mercury_ci.buck import BuckPackagePattern
from mercury_ci.nix import host_nix_system
from mercury_ci.runners import CI_PLATFORMS


FIXTURE_DIR = Path(__file__).parent


def _git(git: str, repo: Path, *args: str) -> str:
    result = subprocess.run(
        [
            git,
            "-c",
            "init.defaultBranch=main",
            "-c",
            "commit.gpgSign=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "protocol.file.allow=always",
            *args,
        ],
        cwd=repo,
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def _isolate_git_config(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    monkeypatch.setenv("GIT_AUTHOR_NAME", "BTD integration test")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "btd@example.invalid")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "BTD integration test")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "btd@example.invalid")
    monkeypatch.setenv("GIT_AUTHOR_DATE", "2000-01-01T00:00:00+00:00")
    monkeypatch.setenv("GIT_COMMITTER_DATE", "2000-01-01T00:00:00+00:00")
    for name in list(os.environ):
        if name in {
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR",
            "GIT_CONFIG_COUNT",
            "GIT_DIR",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_WORK_TREE",
        } or name.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
            monkeypatch.delenv(name, raising=False)


def _copy_repo_fixture(repo: Path) -> None:
    shutil.copy(FIXTURE_DIR / "BUCK.fixture", repo / "BUCK")
    shutil.copy(FIXTURE_DIR / "buckconfig.fixture", repo / ".buckconfig")
    shutil.copy(FIXTURE_DIR / "input.txt", repo / "input.txt")
    shutil.copytree(FIXTURE_DIR / "config", repo / "config")
    (repo / "monolith").mkdir()
    shutil.copy(FIXTURE_DIR / "monolith/BUCK.fixture", repo / "monolith/BUCK")
    shutil.copy(FIXTURE_DIR / "monolith/input.txt", repo / "monolith/input.txt")
    shutil.copytree(FIXTURE_DIR / "prelude", repo / "prelude")


def _make_repo(repo: Path, git: str) -> RevisionPair:
    _copy_repo_fixture(repo)
    _git(git, repo, "init", "-b", "main")
    _git(git, repo, "add", ".")
    _git(git, repo, "commit", "--no-verify", "-m", "base")
    base = GitObjectId(_git(git, repo, "rev-parse", "HEAD"))

    (repo / "input.txt").write_text("head\n")
    (repo / "monolith/input.txt").write_text("head\n")
    _git(git, repo, "add", "input.txt", "monolith/input.txt")
    _git(git, repo, "commit", "--no-verify", "-m", "change inputs")
    head = GitObjectId(_git(git, repo, "rev-parse", "HEAD"))
    return RevisionPair(base, head)


@dataclass(frozen=True, slots=True)
class MiniatureRepo:
    repo: Path
    revisions: RevisionPair
    output_dir: Path
    git: str
    btd: Path
    targets: Path

    def add_cell(self) -> "MiniatureRepo":
        base = self.revisions.head
        shutil.copy(FIXTURE_DIR / "buckconfig-added.fixture", self.repo / ".buckconfig")
        (self.repo / "added").mkdir()
        shutil.copy(FIXTURE_DIR / "added/BUCK.fixture", self.repo / "added/BUCK")
        shutil.copy(FIXTURE_DIR / "added/input.txt", self.repo / "added/input.txt")
        _git(self.git, self.repo, "add", ".buckconfig", "added")
        _git(self.git, self.repo, "commit", "--no-verify", "-m", "add cell")
        head = GitObjectId(_git(self.git, self.repo, "rev-parse", "HEAD"))
        return replace(self, revisions=RevisionPair(base, head))

    def remove_cell(self) -> "MiniatureRepo":
        repo_with_added_cell = self.add_cell()
        base = repo_with_added_cell.revisions.head
        shutil.copy(FIXTURE_DIR / "buckconfig.fixture", self.repo / ".buckconfig")
        _git(self.git, self.repo, "rm", "-r", "added")
        _git(self.git, self.repo, "add", ".buckconfig")
        _git(self.git, self.repo, "commit", "--no-verify", "-m", "remove cell")
        head = GitObjectId(_git(self.git, self.repo, "rev-parse", "HEAD"))
        return replace(self, revisions=RevisionPair(base, head))

    def plan(
        self, exclude_rdeps: list[BuckPackagePattern] | None = None
    ) -> list[PlatformPlan]:
        with ci_actions(exit_on_child_failure=False) as actions:
            return BtdCi(actions, self.btd, self.targets).plan(
                self.repo,
                self.revisions,
                self.output_dir,
                exclude_rdeps=exclude_rdeps,
            )

    def target_artifact(self, system: str) -> object:
        return json.loads((self.output_dir / f"btd-targets-{system}.json").read_text())

    def test_targets(self, targets: list[str]) -> None:
        targets_file = self.output_dir / "test-targets.json"
        targets_file.parent.mkdir(parents=True, exist_ok=True)
        targets_file.write_text(json.dumps(targets))
        system = host_nix_system()
        assert system is not None
        with ci_actions(exit_on_child_failure=False) as actions:
            BtdCi(actions).test(system, targets_file, self.repo)

    def worktrees(self) -> list[str]:
        output = _git(self.git, self.repo, "worktree", "list", "--porcelain")
        return [
            line.removeprefix("worktree ")
            for line in output.splitlines()
            if line.startswith("worktree ")
        ]


@pytest.fixture
def miniature_repo(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> Iterator[MiniatureRepo]:
    _isolate_git_config(monkeypatch)
    git = str(Path(os.environ["GIT_BIN"]).resolve())
    buck2 = str(Path(os.environ["BUCK2_BIN"]).resolve())
    path = os.pathsep.join(
        [str(Path(git).parent), str(Path(buck2).parent), os.environ["PATH"]]
    )
    monkeypatch.setenv("PATH", path)

    repo = tmp_path / "repo"
    repo.mkdir()
    try:
        yield MiniatureRepo(
            repo=repo,
            revisions=_make_repo(repo, git),
            output_dir=tmp_path / "output",
            git=git,
            btd=Path(os.environ["BTD_BIN"]).resolve(),
            targets=Path(os.environ["TARGETS_BIN"]).resolve(),
        )
    finally:
        subprocess.run([buck2, "kill"], cwd=repo, check=False)


def test_plan_finds_reverse_dependencies_in_a_miniature_repo(
    miniature_repo: MiniatureRepo,
) -> None:
    plans = miniature_repo.plan()
    expected_targets = [
        "root//:dependent",
        "root//:leaf",
        "root//:monolith_dependent",
        "root//monolith:leaf",
    ]
    assert [
        (plan.system.nix_system, [str(target) for target in plan.targets])
        for plan in plans
    ] == [(system.nix_system, expected_targets) for system in CI_PLATFORMS]
    for system in CI_PLATFORMS:
        assert miniature_repo.target_artifact(system.nix_system) == expected_targets
    assert miniature_repo.worktrees() == [str(miniature_repo.repo.resolve())]


def test_plan_can_exclude_a_package_and_all_of_its_reverse_dependencies(
    miniature_repo: MiniatureRepo,
) -> None:
    plans = miniature_repo.plan(
        exclude_rdeps=[BuckPackagePattern.parse("root//monolith:")]
    )
    expected_targets = ["root//:dependent", "root//:leaf"]
    assert [
        (plan.system.nix_system, [str(target) for target in plan.targets])
        for plan in plans
    ] == [(system.nix_system, expected_targets) for system in CI_PLATFORMS]


def test_test_runs_an_argfile_and_filters_btd_broken_tests(
    miniature_repo: MiniatureRepo,
) -> None:
    miniature_repo.test_targets(["root//:passing_test", "root//:filtered_failing_test"])


def test_plan_handles_a_cell_added_by_a_root_configuration_change(
    miniature_repo: MiniatureRepo,
) -> None:
    repo_with_added_cell = miniature_repo.add_cell()

    plans = repo_with_added_cell.plan(
        exclude_rdeps=[BuckPackagePattern.parse("root//:")]
    )

    assert [
        (plan.system.nix_system, [str(target) for target in plan.targets])
        for plan in plans
    ] == [(system.nix_system, ["added//:leaf"]) for system in CI_PLATFORMS]


def test_plan_handles_a_cell_removed_by_a_root_configuration_change(
    miniature_repo: MiniatureRepo,
) -> None:
    repo_with_removed_cell = miniature_repo.remove_cell()

    assert (
        repo_with_removed_cell.plan(exclude_rdeps=[BuckPackagePattern.parse("root//:")])
        == []
    )
