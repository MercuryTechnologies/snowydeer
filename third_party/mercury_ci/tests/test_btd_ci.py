# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for Mercury CI build-target determination."""

import json
import shlex
import subprocess
from pathlib import Path

import expecttest
import pytest
from hypothesis import given
from hypothesis import strategies as st

from mercury_ci.btd_ci import (
    BUILD_FILES,
    AffectedTarget,
    BtdCi,
    CellMap,
    CiError,
    GitObjectId,
    PlatformPlan,
    RevisionPair,
    _job_summary,
    make_platform_plans,
    matrix_json,
    parse_targets_file,
    repo_target_patterns,
)
from mercury_ci.buck import BuckPackagePattern, BuckTarget
from mercury_ci.runners import CI_PLATFORMS
from mercury_ci.testing import RecordingCiActions
from mercury_ci.testing.strategies import buck_targets


CELL_OUTPUT = """\
root: /repo
toolchains: /repo/toolchains
nix: /repo/nix
"""


@st.composite
def platform_plan_cases(
    draw: st.DrawFn,
) -> tuple[list[BuckTarget], list[BuckPackagePattern], set[BuckTarget]]:
    """Affected targets plus exclusions derived from them, so overlap occurs."""
    universe = draw(st.lists(buck_targets(), min_size=1, max_size=8))
    affected = draw(st.lists(st.sampled_from(universe), max_size=12))
    excludes = []
    for target in draw(st.lists(st.sampled_from(universe), max_size=3)):
        if target.cell is None:
            continue
        if draw(st.booleans()):
            segments = target.package.split("/") if target.package else []
            depth = draw(st.integers(min_value=0, max_value=len(segments)))
            excludes.append(
                BuckPackagePattern(target.cell, "/".join(segments[:depth]), True)
            )
        else:
            excludes.append(BuckPackagePattern(target.cell, target.package, False))
    excluded_targets = draw(st.sets(st.sampled_from(universe), max_size=4))
    return affected, excludes, excluded_targets


def test_repo_patterns_cover_cross_directory_dependencies_before_exclusion() -> None:
    cells = CellMap.parse(CELL_OUTPUT, Path("/repo"))
    patterns = repo_target_patterns(
        [
            "BUCK",
            "src/Foo/BUCK",
            "test/BUCK",
            "tools/thing/BUCK",
            "snowydeer/BUCK",
            "toolchains/BUCK",
            "nix/packages/BUCK",
        ],
        cells,
    )
    assert patterns == [
        "nix//...",
        "root//...",
        "toolchains//...",
    ]


# FIXME(jadel): we probably want to have some way to rerun buck2-haskell tests
# when we upgrade it. Not sure how yet!
def test_repo_patterns_omit_declared_cells_absent_from_the_tree() -> None:
    cells = CellMap.parse(
        CELL_OUTPUT + "prelude: /repo/prelude\n",
        Path("/repo"),
    )
    assert repo_target_patterns(["tools/BUCK"], cells) == ["root//..."]


# A tiny segment alphabet forces cell roots to nest and file paths to collide
# with them, exercising deepest-cell shadowing far more often than chance.
_dir_paths = st.lists(st.sampled_from(["a", "b", "c"]), min_size=1, max_size=3).map(
    "/".join
)


@st.composite
def cell_trees(draw: st.DrawFn) -> tuple[CellMap, dict[str, Path], list[str]]:
    """A parsed cell map, its name->root table, and repo file paths."""
    cell_dirs = draw(st.lists(_dir_paths, unique=True, max_size=3))
    cells = {"root": Path(".")} | {
        f"cell{index}": Path(directory) for index, directory in enumerate(cell_dirs)
    }
    output = "root: /repo\n" + "".join(
        f"cell{index}: /repo/{directory}\n" for index, directory in enumerate(cell_dirs)
    )
    files = draw(
        st.lists(
            st.tuples(
                st.sampled_from(sorted(str(root) for root in cells.values())),
                st.one_of(st.just(""), _dir_paths),
                st.sampled_from(sorted(BUILD_FILES) + ["README.md", "data.txt"]),
            ),
            max_size=8,
        )
    )
    paths = [
        "/".join(part for part in (base if base != "." else "", subdir, name) if part)
        for base, subdir, name in files
    ]
    return CellMap.parse(output, Path("/repo")), cells, paths


def _deepest_owning_cell(path: Path, cells: dict[str, Path]) -> str:
    """Independent oracle: the longest cell root containing the path wins."""
    owners = [
        (len(root.parts), name)
        for name, root in cells.items()
        if root == Path(".") or root in path.parents
    ]
    return max(owners)[1]


@given(cell_trees())
def test_repo_patterns_are_the_deepest_cells_owning_each_build_file(
    case: tuple[CellMap, dict[str, Path], list[str]],
) -> None:
    cell_map, cells, paths = case
    assert repo_target_patterns(paths, cell_map) == sorted(
        {
            f"{_deepest_owning_cell(Path(path), cells)}//..."
            for path in paths
            if Path(path).name in BUILD_FILES
        }
    )


@given(platform_plan_cases())
def test_platform_plans_schedule_in_scope_targets_once_per_system(
    case: tuple[list[BuckTarget], list[BuckPackagePattern], set[BuckTarget]],
) -> None:
    affected, excludes, excluded_targets = case
    plans = make_platform_plans(
        [AffectedTarget(target) for target in affected], excludes, excluded_targets
    )

    scheduled = plans[0].targets if plans else []
    assert len(set(scheduled)) == len(scheduled)
    assert scheduled == sorted(scheduled, key=str)
    assert [plan.system for plan in plans] == (list(CI_PLATFORMS) if scheduled else [])
    assert all(plan.targets == scheduled for plan in plans)
    for target in set(affected) | set(scheduled):
        in_scope = (
            not any(exclude.matches(target) for exclude in excludes)
            and target not in excluded_targets
        )
        assert (target in scheduled) == (target in affected and in_scope)


# The matrix is the contract with the workflow YAML: key names, runner labels,
# artifact names, and the single-line shape GITHUB_OUTPUT requires.
def test_matrix_json_contains_each_platforms_runner_and_target_artifact() -> None:
    plans = [
        PlatformPlan(CI_PLATFORMS[0], [BuckTarget.parse("root//tools/a:test")]),
        PlatformPlan(CI_PLATFORMS[2], [BuckTarget.parse("root//tools/b:test")]),
    ]
    expecttest.assert_expected_inline(
        matrix_json(plans),
        """{"include":[{"system":"aarch64-linux","runner":"namespace-profile-mwb-build-arm","targets_file":"btd-targets-aarch64-linux.json"},{"system":"aarch64-darwin","runner":"ghcr.io/cirruslabs/macos-runner:sequoia","targets_file":"btd-targets-aarch64-darwin.json"}]}""",
    )


def test_job_summary_links_revisions_and_comparison_on_github(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GITHUB_SERVER_URL", "https://github.example.com")
    monkeypatch.setenv("GITHUB_REPOSITORY", "mercury/mwb")
    revisions = RevisionPair(GitObjectId("0123456"), GitObjectId("89abcde"))
    plans = [
        PlatformPlan(
            CI_PLATFORMS[0],
            [
                BuckTarget.parse("root//tools/a:test"),
                BuckTarget.parse("root//tools/b:test"),
            ],
        ),
        PlatformPlan(CI_PLATFORMS[1], [BuckTarget.parse("root//tools/a:test")]),
    ]

    expecttest.assert_expected_inline(
        _job_summary(plans, revisions),
        """\
## Buck2 target determination

Compared [0123456](https://github.example.com/mercury/mwb/commit/0123456)..[89abcde](https://github.example.com/mercury/mwb/commit/89abcde) ([compare](https://github.example.com/mercury/mwb/compare/0123456..89abcde)).

| System | Targets |
| --- | ---: |
| aarch64-linux | 2 |
| x86_64-linux | 1 |""",
    )


def test_job_summary_uses_plain_revisions_without_github_repository(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("GITHUB_SERVER_URL", raising=False)
    monkeypatch.delenv("GITHUB_REPOSITORY", raising=False)
    revisions = RevisionPair(GitObjectId("0123456"), GitObjectId("89abcde"))

    expecttest.assert_expected_inline(
        _job_summary([], revisions),
        """\
## Buck2 target determination

Compared `0123456` to `89abcde`.

| System | Targets |
| --- | ---: |
| _(none)_ | 0 |""",
    )


def test_reverse_dependency_exclusions_filter_candidates_in_the_head_universe(
    tmp_path: Path,
) -> None:
    actions = RecordingCiActions(
        buck2_handler=lambda _: json.dumps(
            ["root//src:library", "root//unrelated:also-excluded"]
        )
    )
    ci = BtdCi(actions, Path("/tool/btd"), Path("/tool/targets"))

    assert ci._targets_outside_excluded_reverse_dependencies(
        tmp_path,
        ["root//...", "toolchains//..."],
        {
            BuckTarget.parse("root//src:library"),
            BuckTarget.parse("root//tools:dependent"),
            BuckTarget.parse("toolchains//:btd"),
        },
        [
            BuckPackagePattern.parse("root//src/..."),
            BuckPackagePattern.parse("root//:"),
        ],
    ) == {
        BuckTarget.parse("root//tools:dependent"),
        BuckTarget.parse("toolchains//:btd"),
    }
    assert actions.buck2_invocation_args == [
        [
            "uquery",
            "--json",
            'rdeps(set("root//..." "toolchains//..."), set("root//src/..." "root//:"))',
        ]
    ]


def test_missing_reverse_dependency_exclusion_query_output_fails_closed(
    tmp_path: Path,
) -> None:
    actions = RecordingCiActions(buck2_handler=lambda _: "")
    ci = BtdCi(actions, Path("/tool/btd"), Path("/tool/targets"))

    with pytest.raises(CiError, match="produced no JSON output"):
        ci._targets_outside_excluded_reverse_dependencies(
            tmp_path,
            ["root//..."],
            {BuckTarget.parse("root//src:library")},
            [BuckPackagePattern.parse("root//src/...")],
        )


def test_empty_reverse_dependency_exclusion_set_selects_all_candidates(
    tmp_path: Path,
) -> None:
    actions = RecordingCiActions(buck2_handler=lambda _: "[]")
    ci = BtdCi(actions, Path("/tool/btd"), Path("/tool/targets"))
    candidate = BuckTarget.parse("root//src:library")

    assert ci._targets_outside_excluded_reverse_dependencies(
        tmp_path,
        ["root//..."],
        {candidate},
        [BuckPackagePattern.parse("root//src/...")],
    ) == {candidate}


def test_no_reverse_dependency_exclusions_avoid_a_buck_query(
    tmp_path: Path,
) -> None:
    candidate = BuckTarget.parse("root//tools/a:test")
    actions = RecordingCiActions()
    ci = BtdCi(actions, Path("/tool/btd"), Path("/tool/targets"))

    assert ci._targets_outside_excluded_reverse_dependencies(
        tmp_path, ["root//..."], {candidate}, []
    ) == {candidate}
    assert actions.buck2_invocation_args == []


_HEX = "0123456789abcdefABCDEF"


@given(st.text(_HEX, min_size=7, max_size=64))
def test_git_object_id_accepts_hex_of_object_id_length(value: str) -> None:
    assert str(GitObjectId(value)) == value


def _inject_char(parts: tuple[str, int, str]) -> str:
    value, position, char = parts
    index = position % (len(value) + 1)
    return value[:index] + char + value[index:]


_non_object_ids = st.one_of(
    st.text(_HEX, max_size=6),
    st.text(_HEX, min_size=65, max_size=80),
    st.tuples(
        st.text(_HEX, min_size=6, max_size=63),
        st.integers(min_value=0),
        st.characters(blacklist_characters=_HEX),
    ).map(_inject_char),
)


@given(_non_object_ids)
def test_git_object_id_rejects_non_object_ids(value: str) -> None:
    with pytest.raises(ValueError):
        GitObjectId(value)


@given(target=buck_targets(), depth=st.integers())
def test_btd_json_line_parses_target_and_ignores_other_fields(
    target: BuckTarget, depth: int
) -> None:
    line = json.dumps({"target": str(target), "depth": depth, "ignored": True})
    assert AffectedTarget.parse_json_line(line) == AffectedTarget(target)


@pytest.mark.parametrize("value", [{}, {"target": 1, "depth": 0}])
def test_btd_json_line_rejects_missing_or_non_string_target(
    value: dict[str, object],
) -> None:
    with pytest.raises(ValueError, match="BTD target must be a string"):
        AffectedTarget.parse_json_line(json.dumps(value))


def test_worktree_daemon_is_killed_and_worktree_removed_when_planning_fails(
    tmp_path: Path,
) -> None:
    def git_output(args: list[str]) -> str:
        return "" if args[:2] == ["git", "ls-files"] else "BUCK\ntools/BUCK\n"

    actions = RecordingCiActions(
        buck2_handler=lambda _: "not a cell map",
        subprocess_handler=git_output,
    )
    repo = tmp_path / "repo"
    repo.mkdir()
    ci = BtdCi(actions, Path("/tool/btd"), Path("/tool/targets"))
    with pytest.raises(CiError, match="BTD universe phase failed") as failure:
        ci.plan(
            repo,
            RevisionPair(GitObjectId("0123456"), GitObjectId("89abcde")),
        )

    assert isinstance(failure.value.__cause__, ValueError)
    assert actions.root_span_attrs["btd.failure.phase"] == "universe"

    assert actions.subprocess_invocation_args[0][:4] == [
        "git",
        "worktree",
        "add",
        "--detach",
    ]
    assert actions.subprocess_invocation_args[-1][:4] == [
        "git",
        "worktree",
        "remove",
        "--force",
    ]
    assert [inv.cwd for inv in actions.subprocess_invocations][0] == str(repo)
    assert [inv.cwd for inv in actions.subprocess_invocations][-1] == str(repo)
    assert actions.buck2_invocation_args[-1] == ["kill"]
    assert actions.buck2_invocations[-1].cwd is not None
    assert Path(actions.buck2_invocations[-1].cwd).name == "base"


def test_phase_preserves_child_failure_and_exit_code() -> None:
    actions = RecordingCiActions()
    ci = BtdCi(actions)
    failure = subprocess.CalledProcessError(
        17, ["btd"], output=b"captured out", stderr=b"captured err"
    )

    with pytest.raises(subprocess.CalledProcessError) as raised:
        with ci._phase("determination"):
            raise failure

    assert raised.value is failure
    assert actions.root_span_attrs["btd.failure.phase"] == "determination"


def test_runtime_buckconfig_is_mirrored_without_overwriting_tracked_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = tmp_path / "repo"
    checkout = tmp_path / "checkout"
    (repo / ".buckconfig.d").mkdir(parents=True)
    (checkout / ".buckconfig.d").mkdir(parents=True)
    (repo / ".buckconfig.d/90-ci-runtime").write_text("runtime\n")
    (repo / ".buckconfig.d/00-defaults").write_text("head\n")
    (repo / ".buckconfig.local").write_text("local\n")
    (checkout / ".buckconfig.d/00-defaults").write_text("base\n")
    (checkout / ".buckconfig.d/01-mercury-cache").write_text("removed\n")

    ci = BtdCi(RecordingCiActions(), Path("/tool/btd"), Path("/tool/targets"))

    def fake_git(_self: BtdCi, _repo: Path, *args: str) -> str:
        if "--ignored" in args:
            return ".buckconfig.d/90-ci-runtime\n"
        return ".buckconfig.d/00-defaults\n.buckconfig.d/01-mercury-cache\n"

    monkeypatch.setattr(BtdCi, "_git", fake_git)
    ci._sync_runtime_buckconfig(repo, checkout)

    assert (checkout / ".buckconfig.d/90-ci-runtime").read_text() == "runtime\n"
    assert (checkout / ".buckconfig.d/00-defaults").read_text() == "base\n"
    assert (checkout / ".buckconfig.local").read_text() == "local\n"
    assert not (checkout / ".buckconfig.d/01-mercury-cache").exists()


def test_test_command_invokes_buck_for_the_host_platform(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("mercury_ci.btd_ci.host_nix_system", lambda: "x86_64-linux")
    actions = RecordingCiActions(json_files={"targets.json": ["root//tools/a:test"]})
    ci = BtdCi(actions, Path("/tool/btd"), Path("/tool/targets"))
    ci.test("x86_64-linux", Path("targets.json"), tmp_path)
    assert actions.written == [("targets.json.args", "root//tools/a:test\n")]
    expecttest.assert_expected_inline(
        "\n".join(shlex.join(args) for args in actions.buck2_invocation_args),
        """test --skip-incompatible-targets --exclude btd_broken --always-exclude @targets.json.args""",
    )
    assert actions.buck2_invocations[0].cwd == str(tmp_path)


def test_test_command_rejects_a_different_host_without_invoking_buck(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("mercury_ci.btd_ci.host_nix_system", lambda: "x86_64-linux")
    actions = RecordingCiActions(json_files={"targets.json": ["root//tools/a:test"]})
    ci = BtdCi(actions, Path("/tool/btd"), Path("/tool/targets"))
    with pytest.raises(CiError, match="does not match host"):
        ci.test("aarch64-linux", Path("targets.json"))
    assert actions.buck2_invocation_args == []


def test_test_command_rejects_an_empty_target_file_without_invoking_buck(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("mercury_ci.btd_ci.host_nix_system", lambda: "x86_64-linux")
    actions = RecordingCiActions(json_files={"targets.json": []})
    ci = BtdCi(actions, Path("/tool/btd"), Path("/tool/targets"))
    with pytest.raises(CiError, match="no targets"):
        ci.test("x86_64-linux", Path("targets.json"))
    assert actions.buck2_invocation_args == []


@given(st.lists(buck_targets(), max_size=8))
def test_target_file_parser_round_trips_labels_with_order_and_duplicates(
    targets: list[BuckTarget],
) -> None:
    doubled = targets + targets
    assert parse_targets_file([str(target) for target in doubled]) == doubled


@pytest.mark.parametrize(
    "value",
    [None, {}, "root//tools/a:test", [1], ["root//tools/a:test", 1]],
)
def test_target_file_parser_rejects_non_string_arrays(value: object) -> None:
    with pytest.raises(ValueError, match="targets file must contain"):
        parse_targets_file(value)


def test_target_file_parser_rejects_invalid_target_labels() -> None:
    with pytest.raises(ValueError, match="not an absolute Buck label"):
        parse_targets_file(["tools/a:test"])
