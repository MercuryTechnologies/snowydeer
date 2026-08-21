# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Plan and run Buck2 tests selected by buck2-change-detector."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import shutil
import subprocess
import tempfile
from collections.abc import Iterable, Sequence
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
from typing import FrozenSet, Generator

from mercury_ci.actions import (
    AbstractCiActions,
    Buck2,
    BuckOpts,
    TestFilters,
    ci_actions,
)
from mercury_ci.buck import BuckPackagePattern, BuckTarget, CellMap
from mercury_ci.git import GitObjectId
from mercury_ci.nix import host_nix_system
from mercury_ci.runners import CI_PLATFORMS, CiPlatform
from mercury_ci.telemetry import semconv

# @moss-disable[end= ]: from .mercury import setup_worktree

setup_worktree = lambda _actions, _worktree: None  # @moss-enable

BUILD_FILES: FrozenSet[str] = frozenset({"BUCK", "BUCK.v2", "TARGETS", "TARGETS.v2"})
SYSTEM_BY_NAME: dict[str, CiPlatform] = {
    system.nix_system: system for system in CI_PLATFORMS
}


class CiError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True, slots=True)
class RevisionPair:
    """The base and head Git objects compared by target determination."""

    base: GitObjectId
    head: GitObjectId


def repo_target_patterns(paths: Iterable[str], cells: CellMap) -> list[str]:
    """
    Return recursive patterns for every non-empty repository-owned Buck cell, given a
    list of all files in the repository.

    For example, returns `["root//...", "nix//..."]` if given a cell map with
    `root = .`, `nix = nix`, `someothercell = someothercell`, and a file list
    of `["someothercell/BUCK", "nix/BUCK", "src/BUCK"]`.
    """
    cells_with_build_files: set[str] = set()
    for raw_path in paths:
        path = Path(raw_path)
        if path.name not in BUILD_FILES:
            continue
        cell, _ = next(
            (name, root)
            for name, root in cells.roots
            if path == root or root == Path(".") or root in path.parents
        )
        cells_with_build_files.add(cell)
    return sorted(f"{cell}//..." for cell in cells_with_build_files)


@dataclasses.dataclass(frozen=True, slots=True)
class AffectedTarget:
    """A target reported by BTD."""

    target: BuckTarget

    @classmethod
    def parse_json_line(cls, line: str) -> AffectedTarget:
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError("BTD JSON line must be an object")
        target_label = value.get("target")
        if not isinstance(target_label, str):
            raise ValueError("BTD target must be a string")
        return cls(BuckTarget.parse(target_label))


@dataclasses.dataclass(frozen=True, slots=True)
class PlatformPlan:
    """Affected targets scheduled for one supported CI platform."""

    system: CiPlatform
    targets: list[BuckTarget]


def is_in_scope(target: BuckTarget, excludes: Sequence[BuckPackagePattern]) -> bool:
    """Return whether an affected target should be executed by this workflow."""
    return not any(exclude.matches(target) for exclude in excludes)


def scoped_affected_targets(
    affected: Sequence[AffectedTarget],
    excludes: Sequence[BuckPackagePattern],
    excluded_targets: set[BuckTarget] | frozenset[BuckTarget],
) -> set[BuckTarget]:
    """Return affected targets outside direct and reverse-dependency exclusions."""
    return {
        item.target
        for item in affected
        if is_in_scope(item.target, excludes) and item.target not in excluded_targets
    }


def make_platform_plans(
    affected: Sequence[AffectedTarget],
    excludes: Sequence[BuckPackagePattern],
    excluded_targets: set[BuckTarget] | frozenset[BuckTarget] = frozenset(),
) -> list[PlatformPlan]:
    """Schedule sorted in-scope targets on every supported CI platform."""
    targets = sorted(
        scoped_affected_targets(affected, excludes, excluded_targets), key=str
    )
    if not targets:
        return []
    return [PlatformPlan(system, list(targets)) for system in CI_PLATFORMS]


def matrix_json(plans: Sequence[PlatformPlan]) -> str:
    """Serialize platform plans as a GitHub Actions matrix."""
    return json.dumps(
        {
            "include": [
                {
                    "system": plan.system.nix_system,
                    "runner": plan.system.runner,
                    "targets_file": target_file_name(plan.system.nix_system),
                }
                for plan in plans
            ]
        },
        separators=(",", ":"),
    )


def target_file_name(system: str) -> str:
    """Return the artifact filename carrying targets for a Nix system."""
    return f"btd-targets-{system}.json"


def parse_targets_file(parsed: object) -> list[BuckTarget]:
    """Validate and parse a target-list artifact at its JSON boundary."""
    if not isinstance(parsed, list) or not all(
        isinstance(item, str) for item in parsed
    ):
        raise ValueError("targets file must contain a JSON string array")
    return [BuckTarget.parse(item) for item in parsed]


class BtdCi:
    """Plan and execute Buck tests selected by BTD."""

    def __init__(
        self,
        actions: AbstractCiActions,
        btd: Path | None = None,
        targets: Path | None = None,
    ):
        self.actions = actions
        self.buck2 = Buck2(actions)
        self._btd = btd
        self._targets_tool = targets

    @property
    def btd_tool(self) -> Path:
        if self._btd is None:
            raise CiError("BTD executable is not configured")
        return self._btd

    @property
    def targets_tool(self) -> Path:
        if self._targets_tool is None:
            raise CiError("BTD targets tool is not configured")
        return self._targets_tool

    @contextmanager
    def _phase(self, name: str) -> Generator[None]:
        """Add phase context to planner failures and root-span attributes."""
        try:
            yield
        except subprocess.CalledProcessError:
            self.actions.set_root_span_attr(semconv.BTD_FAILURE_PHASE, name)
            raise
        except Exception as error:
            self.actions.set_root_span_attr(semconv.BTD_FAILURE_PHASE, name)
            raise CiError(f"BTD {name} phase failed") from error

    @contextmanager
    def _base_worktree(
        self, repo: Path, parent: Path, revision: GitObjectId
    ) -> Generator[Path]:
        """Create and remove the detached base-revision worktree."""
        checkout = parent / "base"
        added = False
        try:
            with self._phase("worktree"):
                self.actions.run_subprocess(
                    [
                        "git",
                        "worktree",
                        "add",
                        "--detach",
                        str(checkout),
                        str(revision),
                    ],
                    cwd=repo,
                )
                added = True
                self._sync_runtime_buckconfig(repo, checkout)
                setup_worktree(self.actions, repo)
                setup_worktree(self.actions, checkout)
            yield checkout
        finally:
            if added:
                try:
                    self.actions.run_buck2(["kill"], cwd=checkout, check=False)
                finally:
                    self.actions.run_subprocess(
                        ["git", "worktree", "remove", "--force", str(checkout)],
                        cwd=repo,
                        check=False,
                    )

    def _git(self, repo: Path, *args: str) -> str:
        return self.actions.run_subprocess(
            ["git", *args], cwd=repo, capture_output=True
        ).stdout_s

    def _sync_runtime_buckconfig(self, repo: Path, checkout: Path) -> None:
        """Mirror runtime-only Buck config state into the base worktree."""
        local_config = repo / ".buckconfig.local"
        checkout_local_config = checkout / ".buckconfig.local"
        if local_config.is_file():
            shutil.copy2(local_config, checkout_local_config)
        else:
            checkout_local_config.unlink(missing_ok=True)

        ignored = self._git(
            repo,
            "ls-files",
            "--others",
            "--ignored",
            "--exclude-standard",
            "--",
            ".buckconfig.d",
        ).splitlines()
        for relative in ignored:
            source = repo / relative
            destination = checkout / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

        tracked = self._git(repo, "ls-files", "--", ".buckconfig.d").splitlines()
        for relative in tracked:
            if not (repo / relative).exists():
                (checkout / relative).unlink(missing_ok=True)

    def _cells(self, repo: Path) -> CellMap:
        output = self.actions.run_buck2(
            ["audit", "cell"], cwd=repo, capture_output=True
        ).stdout_s
        return CellMap.parse(output, repo)

    def _target_patterns(self, repo: Path, revision: GitObjectId) -> list[str]:
        paths = self._git(
            repo, "ls-tree", "-r", "--name-only", str(revision)
        ).splitlines()
        return repo_target_patterns(paths, self._cells(repo))

    def _graph(self, repo: Path, output: Path, patterns: Sequence[str]) -> None:
        self.actions.run_subprocess(
            [str(self.targets_tool), "--output", str(output), *patterns], cwd=repo
        )

    def _affected(
        self,
        repo: Path,
        changes: Path,
        base_graph: Path,
        head_graph: Path,
        patterns: Sequence[str],
    ) -> list[AffectedTarget]:
        result = self.actions.run_subprocess(
            [
                str(self.btd_tool),
                "--vcs",
                "git",
                "--changes",
                str(changes),
                "--base",
                str(base_graph),
                "--diff",
                str(head_graph),
                "--json-lines",
                *patterns,
            ],
            cwd=repo,
            capture_output=True,
            capture_err=True,
        )
        return [
            AffectedTarget.parse_json_line(line)
            for line in result.stdout_lines
            if line.strip()
        ]

    def _targets_outside_excluded_reverse_dependencies(
        self,
        repo: Path,
        patterns: Sequence[str],
        candidates: set[BuckTarget],
        excluded_packages: Sequence[BuckPackagePattern],
    ) -> set[BuckTarget]:
        if not candidates or not excluded_packages:
            return candidates

        def query_set(values: Iterable[object]) -> str:
            return "set({})".format(
                " ".join(json.dumps(str(value)) for value in values)
            )

        labels = self.buck2.uquery(
            "rdeps({}, {})".format(query_set(patterns), query_set(excluded_packages)),
            cwd=repo,
        )
        if labels == {}:
            raise CiError("buck2 uquery produced no JSON output")
        if not isinstance(labels, list) or not all(
            isinstance(label, str) for label in labels
        ):
            raise ValueError("buck2 uquery output must be a JSON string array")
        excluded_targets = {BuckTarget.parse(label) for label in labels}
        return candidates - excluded_targets

    def plan(
        self,
        repo: Path,
        revisions: RevisionPair,
        output_dir: Path = Path("."),
        excludes: Sequence[BuckPackagePattern] | None = None,
        exclude_rdeps: Sequence[BuckPackagePattern] | None = None,
    ) -> list[PlatformPlan]:
        """Determine affected targets and write the CI matrix artifacts."""
        repo = repo.resolve()
        exclusions = [] if excludes is None else excludes
        reverse_dependency_roots = [] if exclude_rdeps is None else exclude_rdeps
        self.actions.set_root_span_attrs(
            {
                semconv.BTD_BASE_REVISION: str(revisions.base),
                semconv.VCS_REF_HEAD_REVISION: str(revisions.head),
            }
        )
        with tempfile.TemporaryDirectory(prefix="btd-ci-") as temp:
            temp_root = Path(temp)
            with self._base_worktree(repo, temp_root, revisions.base) as base_checkout:
                with self._phase("universe"):
                    with ThreadPoolExecutor(max_workers=2) as executor:
                        base_patterns_future = executor.submit(
                            self._target_patterns, base_checkout, revisions.base
                        )
                        head_patterns_future = executor.submit(
                            self._target_patterns, repo, revisions.head
                        )
                        base_patterns = base_patterns_future.result()
                        head_patterns = head_patterns_future.result()
                    patterns = sorted(set(base_patterns) | set(head_patterns))
                    self.actions.set_root_span_attr(
                        semconv.BTD_UNIVERSE_PATTERN_COUNT, len(patterns)
                    )

                with self._phase("graph"):
                    base_graph = temp_root / "base.jsonl"
                    head_graph = temp_root / "head.jsonl"
                    changes = temp_root / "changes"
                    with ThreadPoolExecutor(max_workers=3) as executor:
                        base_graph_future = executor.submit(
                            self._graph, base_checkout, base_graph, base_patterns
                        )
                        head_graph_future = executor.submit(
                            self._graph, repo, head_graph, head_patterns
                        )
                        changes_future = executor.submit(
                            self._git,
                            repo,
                            "diff",
                            "--name-status",
                            "--find-renames",
                            str(revisions.base),
                            str(revisions.head),
                        )
                        base_graph_future.result()
                        head_graph_future.result()
                        changes_text = changes_future.result()
                    self.actions.write_file(
                        changes,
                        changes_text,
                    )
                    self.actions.set_root_span_attrs(
                        {
                            semconv.BTD_BASE_GRAPH_TARGET_COUNT: _line_count(
                                base_graph
                            ),
                            semconv.BTD_HEAD_GRAPH_TARGET_COUNT: _line_count(
                                head_graph
                            ),
                        }
                    )

                with self._phase("determination"):
                    affected = self._affected(
                        repo, changes, base_graph, head_graph, patterns
                    )
                    candidate_targets = scoped_affected_targets(
                        affected, exclusions, frozenset()
                    )
                    selected_targets = (
                        self._targets_outside_excluded_reverse_dependencies(
                            repo,
                            head_patterns,
                            candidate_targets,
                            reverse_dependency_roots,
                        )
                    )
                    self.actions.set_root_span_attr(
                        semconv.BTD_AFFECTED_TARGET_COUNT, len(affected)
                    )
                    affected_targets = {item.target for item in affected}
                    self.actions.set_root_span_attrs(
                        {
                            semconv.BTD_SELECTED_TARGET_COUNT: len(selected_targets),
                            semconv.BTD_EXCLUDED_TARGET_COUNT: len(
                                affected_targets - selected_targets
                            ),
                        }
                    )
                    plans = make_platform_plans(
                        affected,
                        exclusions,
                        candidate_targets - selected_targets,
                    )
                    target_counts = {
                        plan.system.nix_system: len(plan.targets) for plan in plans
                    }
                    self.actions.set_root_span_attrs(
                        {
                            f"{semconv.BTD_TARGET_COUNT}.{system.nix_system}": target_counts.get(
                                system.nix_system, 0
                            )
                            for system in CI_PLATFORMS
                        }
                    )
                for plan in plans:
                    self.actions.write_file(
                        output_dir / target_file_name(plan.system.nix_system),
                        json.dumps([str(target) for target in plan.targets]) + "\n",
                    )
                matrix = matrix_json(plans)
                self.actions.write_github_output("matrix", matrix)
                self.actions.write_github_output(
                    "has_targets", str(bool(plans)).lower()
                )
                self.actions.write_github_step_summary(_job_summary(plans, revisions))
                return plans

    def test(
        self, system_name: str, targets_file: Path, repo: Path | None = None
    ) -> None:
        """Run a platform artifact's nonempty target list on its host."""
        try:
            system = SYSTEM_BY_NAME[system_name]
        except KeyError as error:
            raise CiError(f"unsupported system: {system_name!r}") from error
        actual = host_nix_system()
        if actual != system.nix_system:
            raise CiError(
                f"--system {system.nix_system!r} does not match host {actual!r}"
            )
        targets = parse_targets_file(self.actions.read_json_file(targets_file))
        if not targets:
            raise CiError("refusing to invoke buck2 test with no targets")
        repo = Path.cwd() if repo is None else repo.resolve()
        setup_worktree(self.actions, repo)
        argfile = targets_file.with_suffix(f"{targets_file.suffix}.args")
        self.actions.write_file(argfile, "".join(f"{target}\n" for target in targets))
        self.buck2.test(
            [f"@{argfile}"],
            opts=BuckOpts(extra=["--skip-incompatible-targets"]),
            filters=TestFilters(
                exclude=["btd_broken"],
                always_exclude=True,
                # FIXME(DUX-5660): Build filtered tests once every btd_broken
                # target can at least compile successfully.
            ),
            cwd=repo,
        )


def _line_count(path: Path) -> int:
    """Count newline-delimited graph records."""
    with path.open("rb") as handle:
        return sum(1 for _ in handle)


def _job_summary(plans: Sequence[PlatformPlan], revisions: RevisionPair) -> str:
    """Format the human-readable target plan as GitHub-flavored Markdown."""
    base = str(revisions.base)
    head = str(revisions.head)
    server_url = os.environ.get("GITHUB_SERVER_URL")
    repository = os.environ.get("GITHUB_REPOSITORY")
    if server_url and repository:
        repository_url = f"{server_url.rstrip('/')}/{repository}"
        comparison = (
            f"[{base}]({repository_url}/commit/{base}).."
            f"[{head}]({repository_url}/commit/{head}) "
            f"([compare]({repository_url}/compare/{base}..{head}))."
        )
    else:
        comparison = f"`{base}` to `{head}`."
    rows = [
        "## Buck2 target determination",
        "",
        f"Compared {comparison}",
        "",
        "| System | Targets |",
        "| --- | ---: |",
    ]
    # FIXME(jadel): we should probably show some exemplar targets in this
    # output. Not all of them, and it's hard to exactly figure out how to
    # describe the most consequential ones to influence human decision-making:
    # maybe the ones with the most deps (the most expensive ones)?
    rows.extend(f"| {plan.system.nix_system} | {len(plan.targets)} |" for plan in plans)
    if not plans:
        rows.append("| _(none)_ | 0 |")
    return "\n".join(rows)


def cli_main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan")
    plan.add_argument("--btd", required=True, type=Path)
    plan.add_argument("--targets", required=True, type=Path)
    plan.add_argument("--base", required=True)
    plan.add_argument("--head", required=True)
    plan.add_argument("--output-dir", default=Path.cwd(), type=Path)
    plan.add_argument("--repo", default=Path.cwd(), type=Path)
    plan.add_argument(
        "--exclude",
        action="append",
        default=[],
        type=BuckPackagePattern.parse,
        help=(
            "exclude an exact (`cell//pkg:`) or recursive (`cell//pkg/...`) "
            "package from CI execution"
        ),
    )
    plan.add_argument(
        "--exclude-rdeps",
        action="append",
        default=[],
        type=BuckPackagePattern.parse,
        help=(
            "exclude an exact (`cell//pkg:`) or recursive (`cell//pkg/...`) "
            "package and all of its reverse dependencies from CI execution"
        ),
    )
    test = commands.add_parser("test")
    test.add_argument("--repo", default=Path.cwd(), type=Path)
    test.add_argument("--system", required=True, choices=sorted(SYSTEM_BY_NAME))
    test.add_argument("--targets-file", required=True, type=Path)
    args = parser.parse_args()

    with ci_actions() as actions:
        match args.command:
            case "plan":
                BtdCi(actions, args.btd, args.targets).plan(
                    args.repo,
                    RevisionPair(GitObjectId(args.base), GitObjectId(args.head)),
                    args.output_dir,
                    args.exclude,
                    args.exclude_rdeps,
                )
            case "test":
                BtdCi(actions).test(args.system, args.targets_file, args.repo)
            case _:
                raise AssertionError(f"unreachable command: {args.command}")


if __name__ == "__main__":
    cli_main()
