# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for the `mercury_ci.actions.Buck2` command shapes."""

from collections.abc import Callable

import pytest
from hypothesis import given

from mercury_ci.actions import Buck2, BuckOpts, TestFilters, is_full_mercury_repo
from mercury_ci.testing import RecordingCiActions
from mercury_ci.testing.strategies import buck_opts, test_filters

FROM_SOURCE = BuckOpts(argfiles=["constraints/bootstrap_mode/from_source.args"])


def test_buck2_forwards_working_directory() -> None:
    actions = RecordingCiActions()
    Buck2(actions).build(["//a"], cwd="/checkout")
    assert [inv.cwd for inv in actions.buck2_invocations] == ["/checkout"]


def test_cquery_forwards_working_directory() -> None:
    actions = RecordingCiActions(buck2_handler=lambda _: b"[]")
    Buck2(actions).cquery("//...", cwd="/checkout")
    assert actions.buck2_invocations[0].cwd == "/checkout"


def test_is_full_mercury_repo_forwards_working_directory() -> None:
    actions = RecordingCiActions(
        buck2_handler=lambda _: b'{"mercury.is_full_mercury_repo":"true"}'
    )
    assert is_full_mercury_repo(actions, cwd="/checkout")
    assert actions.buck2_invocations[0].cwd == "/checkout"


def test_build_without_opts_is_backward_compatible() -> None:
    actions = RecordingCiActions()
    Buck2(actions).build(["//a", "//b"])
    assert actions.buck2_invocation_args == [["build", "--", "//a", "//b"]]


def test_run_without_opts_is_backward_compatible() -> None:
    actions = RecordingCiActions()
    Buck2(actions).run("//a", ["x", "y"])
    assert actions.buck2_invocation_args == [["run", "//a", "--", "x", "y"]]


def test_test_without_test_args_omits_the_separator() -> None:
    # Everything after `--` is arguments to the test binaries, so an empty one
    # is not harmless.
    actions = RecordingCiActions()
    Buck2(actions).test(["//a", "//b"])
    assert actions.buck2_invocation_args == [["test", "//a", "//b"]]


def test_test_serializes_filters_then_targets_then_test_args() -> None:
    actions = RecordingCiActions()
    Buck2(actions).test(
        ["//a"],
        test_args=["--verbose"],
        filters=TestFilters(exclude=["hlint"], always_exclude=True),
    )
    assert actions.buck2_invocation_args == [
        ["test", "--exclude", "hlint", "--always-exclude", "//a", "--", "--verbose"]
    ]


def test_build_serializes_modifiers() -> None:
    actions = RecordingCiActions()
    Buck2(actions).build(["//a"], opts=BuckOpts(modifiers=["release", "static"]))
    assert actions.buck2_invocation_args == [
        ["build", "-m", "release", "-m", "static", "--", "//a"]
    ]


def test_run_serializes_opts_before_target() -> None:
    actions = RecordingCiActions()
    Buck2(actions).run("//a", ["--upload"], opts=BuckOpts(modifiers=["release"]))
    assert actions.buck2_invocation_args == [
        ["run", "-m", "release", "//a", "--", "--upload"]
    ]


def test_argfiles_precede_the_flags_that_override_them() -> None:
    actions = RecordingCiActions()
    Buck2(actions).build(
        ["//a"], opts=FROM_SOURCE | BuckOpts(configs={"mercury.thing": "1"})
    )
    assert actions.buck2_invocation_args == [
        [
            "build",
            "@constraints/bootstrap_mode/from_source.args",
            "-c",
            "mercury.thing=1",
            "--",
            "//a",
        ]
    ]


def test_bound_opts_apply_to_every_command() -> None:
    actions = RecordingCiActions()
    buck2 = Buck2(actions).with_opts(FROM_SOURCE)
    buck2.build(["//a"])
    buck2.run("//a")
    modefile = "@constraints/bootstrap_mode/from_source.args"
    assert actions.buck2_invocation_args == [
        ["build", modefile, "--", "//a"],
        ["run", modefile, "//a", "--"],
    ]


def test_with_opts_does_not_affect_the_original() -> None:
    actions = RecordingCiActions()
    buck2 = Buck2(actions)
    buck2.with_opts(FROM_SOURCE)
    buck2.build(["//a"])
    assert actions.buck2_invocation_args == [["build", "--", "//a"]]


def test_uquery_requests_json_with_attributes() -> None:
    actions = RecordingCiActions(buck2_handler=lambda _: b"{}")
    Buck2(actions).uquery("kind(x, //...)", ["compatible_with", "labels"])
    assert actions.buck2_invocation_args == [
        [
            "uquery",
            "--json",
            "kind(x, //...)",
            "--output-attribute",
            "compatible_with",
            "--output-attribute",
            "labels",
        ]
    ]


def test_utargets_requests_json_with_attributes() -> None:
    actions = RecordingCiActions(buck2_handler=lambda _: b'[{"labels": ["fast"]}]')
    result = Buck2(actions).utargets(["//..."], ["^labels$"])
    assert actions.buck2_invocation_args == [
        ["utargets", "--json", "//...", "--output-attribute", "^labels$"]
    ]
    assert result == [{"labels": ["fast"]}]


def test_uquery_requests_json_without_attributes() -> None:
    # --json must be present so a bare query yields parseable JSON, not text.
    actions = RecordingCiActions(buck2_handler=lambda _: b'["//a", "//b"]')
    result = Buck2(actions).uquery("q")
    assert actions.buck2_invocation_args == [["uquery", "--json", "q"]]
    assert result == ["//a", "//b"]


def test_uquery_parses_object() -> None:
    actions = RecordingCiActions(
        buck2_handler=lambda _: b'{"//a": {"compatible_with": ["//p:x"]}}'
    )
    assert Buck2(actions).uquery("q", ["compatible_with"]) == {
        "//a": {"compatible_with": ["//p:x"]}
    }


def test_uquery_empty_stdout_maps_to_empty() -> None:
    actions = RecordingCiActions(buck2_handler=lambda _: b"   \n")
    assert Buck2(actions).uquery("q") == {}


# --- monoid laws ---


@given(buck_opts, buck_opts, buck_opts)
def test_opts_merge_is_associative(a: BuckOpts, b: BuckOpts, c: BuckOpts) -> None:
    assert ((a | b) | c) == (a | (b | c))


@given(buck_opts)
def test_empty_opts_is_the_identity(a: BuckOpts) -> None:
    assert (BuckOpts() | a) == a == (a | BuckOpts())


@given(test_filters, test_filters, test_filters)
def test_filters_merge_is_associative(
    a: TestFilters, b: TestFilters, c: TestFilters
) -> None:
    assert ((a | b) | c) == (a | (b | c))


@given(test_filters)
def test_empty_filters_is_the_identity(a: TestFilters) -> None:
    assert (TestFilters() | a) == a == (a | TestFilters())


def test_merging_appends_within_each_category() -> None:
    # `to_args` emits a category at a time, so a merge interleaves by category
    # rather than concatenating the two command lines. Within a category the
    # right-hand side lands last, which is how buck2 resolves a conflict.
    a = BuckOpts(argfiles=["a.args"], configs={"k": "1"}, modifiers=["one"])
    b = BuckOpts(argfiles=["b.args"], configs={"k": "2"}, modifiers=["two"])
    assert (a | b).to_args() == [
        "@a.args",
        "@b.args",
        # A repeated key collapses in the dict union rather than being emitted
        # twice for buck2 to resolve.
        "-c",
        "k=2",
        "-m",
        "one",
        "-m",
        "two",
    ]


def test_extra_flags_are_emitted_after_the_modelled_ones() -> None:
    opts = BuckOpts(extra=["--some-new-flag"]) | BuckOpts(modifiers=["release"])
    assert opts.to_args() == ["-m", "release", "--some-new-flag"]


def test_unset_target_platforms_means_none_rather_than_falsey() -> None:
    # `--target-platforms ''` is a value the right-hand side can legitimately
    # impose, so the merge tests for `None` and not for truthiness.
    assert (BuckOpts(target_platforms="x") | BuckOpts()).target_platforms == "x"
    assert (
        BuckOpts(target_platforms="x") | BuckOpts(target_platforms="")
    ).target_platforms == ""


# --- how options compose into a command ---


def argv_of(invoke: Callable[[Buck2], object]) -> list[str]:
    """The single buck2 command line that `invoke` produces."""
    actions = RecordingCiActions(buck2_handler=lambda _: b"{}")
    invoke(Buck2(actions))
    (call,) = actions.buck2_invocation_args
    return call


# One representative invocation per subcommand, each with its positionals
# already populated so that an option landing in the wrong section shows up.
# Keyed by the buck2 subcommand it should emit, which is two words for some.
COMMANDS: list[tuple[str, Callable[[Buck2, BuckOpts], object]]] = [
    ("build", lambda buck2, opts: buck2.build(["//a", "//b"], opts=opts)),
    ("run", lambda buck2, opts: buck2.run("//a", ["--program-arg"], opts=opts)),
    (
        "test",
        lambda buck2, opts: buck2.test(
            ["//a"],
            test_args=["--test-arg"],
            filters=TestFilters(exclude=["hlint"]),
            opts=opts,
        ),
    ),
    ("uquery", lambda buck2, opts: buck2.uquery("//...", ["labels"], opts=opts)),
    ("audit config", lambda buck2, opts: buck2.get_config(opts)),
]


@pytest.mark.parametrize("subcommand,invoke", COMMANDS)
@given(buck_opts)
def test_options_only_insert_a_prefix_group(
    subcommand: str,
    invoke: Callable[[Buck2, BuckOpts], object],
    opts: BuckOpts,
) -> None:
    # Whatever a subcommand does with its positionals, supplying options may
    # only splice a run of flags in directly after the subcommand: it may not
    # reorder, drop, or step on anything else. This is what makes them "prefix"
    # options, and it is the property that fails if one lands after a `--`.
    words = subcommand.split()
    plain = argv_of(lambda buck2: invoke(buck2, BuckOpts()))
    with_opts = argv_of(lambda buck2: invoke(buck2, opts))
    assert plain[: len(words)] == words
    assert with_opts == plain[: len(words)] + opts.to_args() + plain[len(words) :]


@pytest.mark.parametrize("subcommand,invoke", COMMANDS)
@given(buck_opts, buck_opts)
def test_the_three_ways_to_supply_options_agree(
    subcommand: str,
    invoke: Callable[[Buck2, BuckOpts], object],
    a: BuckOpts,
    b: BuckOpts,
) -> None:
    bound_twice = argv_of(
        lambda buck2: invoke(buck2.with_opts(a).with_opts(b), BuckOpts())
    )
    bound_merged = argv_of(lambda buck2: invoke(buck2.with_opts(a | b), BuckOpts()))
    bound_and_passed = argv_of(lambda buck2: invoke(buck2.with_opts(a), b))
    assert bound_twice == bound_merged == bound_and_passed


def test_get_config_considers_modefiles() -> None:
    actions = RecordingCiActions(buck2_handler=lambda _: b"{}")
    Buck2(actions).with_opts(FROM_SOURCE).get_config()
    assert actions.buck2_invocation_args == [
        [
            "audit",
            "config",
            "@constraints/bootstrap_mode/from_source.args",
            "--json",
        ]
    ]


def test_program_args_that_look_like_buck2_flags_are_not_intercepted() -> None:
    actions = RecordingCiActions()
    Buck2(actions).run("//a", ["-m", "not-a-modifier"])
    assert actions.buck2_invocation_args == [
        ["run", "//a", "--", "-m", "not-a-modifier"]
    ]
