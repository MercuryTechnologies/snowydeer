# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for the buck2/tpx <-> pytest bridge in `tpx_pytest_bridge`.

These cover the pure helpers, the three pytest plugins (list, regex
filter, JSON reporter), exit-code mapping, argv parsing, and `main()`'s
top-level orchestration. `main()` tests monkeypatch `pytest.main` so we
exercise our code without re-entering a real pytest session; `argv` and
`test_modules` are passed directly into `main()` as arguments.
"""

import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any, cast

import pytest
from pytest import MonkeyPatch
from pytest import CaptureFixture

from third_party.python.pytest import tpx_pytest_bridge


def _fake_item(
    *,
    nodeid: str,
    name: str,
    module_name: str | None = None,
    cls: type | None = None,
) -> tpx_pytest_bridge._PytestItem:
    """Minimal stand-in for a `pytest.Item`.

    `module=None` simulates the collection-error path where pytest hasn't
    attached `item.module` yet.
    """
    module = SimpleNamespace(__name__=module_name) if module_name is not None else None
    return cast(
        tpx_pytest_bridge._PytestItem,
        SimpleNamespace(nodeid=nodeid, name=name, module=module, cls=cls),
    )


def _fake_cls(name: str, qualname: str | None = None) -> type:
    """Build a dummy class with a controlled `__name__` / `__qualname__`.

    Defining nested classes at module scope risks pytest collecting them
    as test classes; build them programmatically instead.
    """
    cls = type(name, (), {})
    cls.__qualname__ = qualname if qualname is not None else name
    return cls


def _report(**fields: Any) -> tpx_pytest_bridge._PytestReport:
    """Stand-in for a `pytest.TestReport` with sane defaults."""
    defaults: dict[str, Any] = {
        "nodeid": "a.py::test_x",
        "when": "call",
        "duration": 0.0,
        "capstdout": "",
        "capstderr": "",
        "longrepr": None,
        "passed": False,
        "failed": False,
        "skipped": False,
    }
    defaults.update(fields)
    return cast(tpx_pytest_bridge._PytestReport, SimpleNamespace(**defaults))


def _fake_session(
    items: list[tpx_pytest_bridge._PytestItem] | None = None,
) -> tpx_pytest_bridge._PytestSession:
    """Stand-in for a `pytest.Session`. Only `.items` is read by our hooks."""
    return cast(tpx_pytest_bridge._PytestSession, SimpleNamespace(items=items or []))


def _expected_result(**fields: Any) -> tpx_pytest_bridge._TpxResult:
    """Expected JSON record with defaults matching the empty/successful state.

    Tests build the full expected dict via overrides and compare with `==`,
    so extra/missing fields and stale defaults fail loudly.
    """
    defaults: tpx_pytest_bridge._TpxResult = {
        "testCaseName": "a",
        "testCase": "test_x",
        "type": "SUCCESS",
        "time": 0,
        "message": "",
        "stacktrace": None,
        "stdOut": "",
        "stdErr": "",
    }
    defaults.update(fields)  # type: ignore[typeddict-item]
    return defaults


# --- _is_test_module --------------------------------------------------------


@pytest.mark.parametrize(
    "module,expected",
    [
        ("test_foo", True),
        ("pkg.test_foo", True),
        ("pkg.subpkg.test_foo", True),
        ("foo_test", True),
        ("pkg.foo_test", True),
        ("foo", False),
        ("pkg.foo", False),
        # First segment is `test_*` but the *last* segment isn't -- not a
        # test module under pytest's default discovery rules.
        ("test_pkg.helpers", False),
        ("pkg.tests", False),
    ],
)
def test_is_test_module(module: str, expected: bool) -> None:
    assert tpx_pytest_bridge._is_test_module(module) is expected


# --- _nodeid_to_module ------------------------------------------------------


@pytest.mark.parametrize(
    "nodeid,expected",
    [
        ("pkg/test_foo.py", "pkg.test_foo"),
        ("pkg/test_foo.py::test_bar", "pkg.test_foo"),
        ("pkg/test_foo.py::TestC::test_bar", "pkg.test_foo"),
        ("test_top.py", "test_top"),
        # Windows-style separators get normalized too.
        ("pkg\\test_foo.py", "pkg.test_foo"),
        # Non-`.py` path is returned as-is (minus separator normalization).
        ("pkg/notapy::test_x", "pkg.notapy"),
    ],
)
def test_nodeid_to_module(nodeid: str, expected: str) -> None:
    assert tpx_pytest_bridge._nodeid_to_module(nodeid) == expected


# --- _test_case_name & _buck_test_id ---------------------------------------


def test_test_case_name_module_only() -> None:
    item = _fake_item(
        nodeid="pkg/test_foo.py::test_bar",
        name="test_bar",
        module_name="pkg.test_foo",
    )
    assert tpx_pytest_bridge._test_case_name(item) == "pkg.test_foo"


def test_test_case_name_with_class_uses_name_by_default() -> None:
    cls = _fake_cls("Inner", qualname="Outer.Inner")
    item = _fake_item(
        nodeid="x.py::Outer::Inner::test_z",
        name="test_z",
        module_name="x",
        cls=cls,
    )
    assert tpx_pytest_bridge._test_case_name(item) == "x.Inner"


def test_test_case_name_use_qualname_for_nested_class() -> None:
    cls = _fake_cls("Inner", qualname="Outer.Inner")
    item = _fake_item(
        nodeid="x.py::Outer::Inner::test_z",
        name="test_z",
        module_name="x",
        cls=cls,
    )
    assert tpx_pytest_bridge._test_case_name(item, use_qualname=True) == "x.Outer.Inner"


def test_test_case_name_falls_back_to_nodeid_when_module_missing() -> None:
    """When `item.module` is None (e.g. collection error), derive from nodeid."""
    item = _fake_item(
        nodeid="pkg/test_foo.py::test_bar", name="test_bar", module_name=None
    )
    assert tpx_pytest_bridge._test_case_name(item) == "pkg.test_foo"


def test_buck_test_id_format() -> None:
    item = _fake_item(
        nodeid="pkg/test_foo.py::test_bar",
        name="test_bar",
        module_name="pkg.test_foo",
    )
    assert tpx_pytest_bridge._buck_test_id(item) == "pkg.test_foo#test_bar"


def test_buck_test_id_with_class() -> None:
    cls = _fake_cls("TestC")
    item = _fake_item(
        nodeid="pkg/test_foo.py::TestC::test_bar",
        name="test_bar",
        module_name="pkg.test_foo",
        cls=cls,
    )
    assert tpx_pytest_bridge._buck_test_id(item) == "pkg.test_foo.TestC#test_bar"


# --- _extract_skip_reason ---------------------------------------------------


@pytest.mark.parametrize(
    "longrepr,expected",
    [
        # `skipif` markers produce `(file, lineno, reason)` triples; take the
        # last element so 2-/4-tuples still produce a sensible message.
        (("a.py", 7, "needs-network"), "needs-network"),
        (("only", "two"), "two"),
        # `pytest.skip(reason=...)` produces a string longrepr like
        # `"Skipped: ..."`; the prefix is stripped so callers don't render
        # `"Skipped: Skipped: ..."`.
        ("Skipped: manual", "manual"),
        ("bare reason", "bare reason"),
        # No reason at all: caller renders a bare label.
        (None, ""),
        # Empty tuple must not fall through to `str(())` == `"()"`; that
        # would surface as a meaningless `"Skipped: ()"` message.
        ((), ""),
    ],
)
def test_extract_skip_reason(longrepr: Any, expected: str) -> None:
    assert tpx_pytest_bridge._extract_skip_reason(longrepr) == expected


# --- _RegexFilterPlugin -----------------------------------------------------


def test_regex_filter_keeps_matching_items_and_mutates_list_in_place() -> None:
    items = [
        _fake_item(nodeid="a.py::test_keep", name="test_keep", module_name="a"),
        _fake_item(nodeid="b.py::test_drop", name="test_drop", module_name="b"),
        _fake_item(nodeid="c.py::test_keep2", name="test_keep2", module_name="c"),
    ]
    original_ref = items
    tpx_pytest_bridge._RegexFilterPlugin("test_keep").pytest_collection_modifyitems(
        items
    )
    # pytest_collection_modifyitems is documented to mutate in place; verify
    # we're not rebinding the local but actually modifying the caller's list.
    assert items is original_ref
    assert [it.name for it in items] == ["test_keep", "test_keep2"]


def test_regex_filter_uses_search_not_fullmatch() -> None:
    """`re.search` semantics mean partial matches count -- guard against a
    future switch to `fullmatch`/`match` that would silently drop tests."""
    items = [_fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")]
    tpx_pytest_bridge._RegexFilterPlugin("test_").pytest_collection_modifyitems(items)
    assert len(items) == 1


def test_regex_filter_drops_everything_on_no_match() -> None:
    items = [_fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")]
    tpx_pytest_bridge._RegexFilterPlugin("nope").pytest_collection_modifyitems(items)
    assert items == []


def test_regex_filter_empty_pattern_matches_everything_in_isolation() -> None:
    """The plugin's own behavior with an empty pattern is `re.search("", id)`,
    which matches every string. Pin this so a future switch from `re.search`
    to `re.match`/`re.fullmatch` -- which would silently flip this to
    "match nothing" -- breaks loudly.

    Note: `main()` short-circuits and does NOT construct this plugin for an
    empty `--regex ""` (treated there as "no filter applied"); this test
    locks down the plugin's own contract for callers that bypass main()."""
    items = [
        _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a"),
        _fake_item(nodeid="b.py::test_y", name="test_y", module_name="b"),
    ]
    tpx_pytest_bridge._RegexFilterPlugin("").pytest_collection_modifyitems(items)
    assert [it.name for it in items] == ["test_x", "test_y"]


# --- _ListPlugin ------------------------------------------------------------


def test_list_plugin_python_format(capsys: CaptureFixture[str]) -> None:
    cls = _fake_cls("TestY")
    items = [
        _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a"),
        _fake_item(
            nodeid="a.py::TestY::test_z", name="test_z", module_name="a", cls=cls
        ),
    ]
    tpx_pytest_bridge._ListPlugin("python").pytest_collection_finish(
        _fake_session(items)
    )
    assert capsys.readouterr().out == "test_x (a)\ntest_z (a.TestY)\n"


def test_list_plugin_buck_format(capsys: CaptureFixture[str]) -> None:
    items = [_fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")]
    tpx_pytest_bridge._ListPlugin("buck").pytest_collection_finish(_fake_session(items))
    assert capsys.readouterr().out == "a#test_x\n"


# --- _map_exit_code ---------------------------------------------------------


@pytest.mark.parametrize(
    "pytest_code,expected",
    [
        (0, 0),
        (1, 70),  # test failures
        (2, 70),  # interrupted
        (3, 70),  # internal error
        (4, 70),  # usage error
        (5, 70),  # no tests collected
    ],
)
def test_map_exit_code(pytest_code: int, expected: int) -> None:
    assert tpx_pytest_bridge._map_exit_code(pytest_code) == expected


# --- _parse_argv ------------------------------------------------------------


def test_parse_argv_defaults() -> None:
    args, rest = tpx_pytest_bridge._parse_argv([])
    assert args.list is False
    assert args.list_format == "python"
    assert args.output is None
    assert args.regex is None
    assert rest == []


def test_parse_argv_recognises_long_forms() -> None:
    args, rest = tpx_pytest_bridge._parse_argv(
        [
            "--list-tests",
            "--list-format",
            "buck",
            "--output",
            "/tmp/o.json",
            "--regex",
            "foo",
        ]
    )
    assert args.list is True
    assert args.list_format == "buck"
    assert args.output == "/tmp/o.json"
    assert args.regex == "foo"
    assert rest == []


def test_parse_argv_forwards_unknown_args() -> None:
    args, rest = tpx_pytest_bridge._parse_argv(
        ["--regex", "x", "-k", "pat", "-x", "--tb=short"]
    )
    assert args.regex == "x"
    assert rest == ["-k", "pat", "-x", "--tb=short"]


def test_parse_argv_does_not_consume_short_l() -> None:
    """`-l` is pytest's `--showlocals`; must not be parsed as `--list-tests`."""
    args, rest = tpx_pytest_bridge._parse_argv(["-l"])
    assert args.list is False
    assert rest == ["-l"]


def test_parse_argv_does_not_consume_short_o() -> None:
    """`-o` is pytest's ini override; must not be parsed as `--output`."""
    args, rest = tpx_pytest_bridge._parse_argv(["-o", "x=1"])
    assert args.output is None
    assert rest == ["-o", "x=1"]


def test_parse_argv_does_not_prefix_match_long_options() -> None:
    """`--reg=foo` (or any unknown long option sharing a prefix with ours)
    must pass through to pytest, not get swallowed as `--regex foo`."""
    args, rest = tpx_pytest_bridge._parse_argv(["--reg=foo"])
    assert args.regex is None
    assert rest == ["--reg=foo"]


# --- _BuckJsonReporter ------------------------------------------------------


def _reporter_with_items(
    items: list[tpx_pytest_bridge._PytestItem], path: str
) -> tpx_pytest_bridge._BuckJsonReporter:
    rep = tpx_pytest_bridge._BuckJsonReporter(path)
    rep.pytest_collection_finish(_fake_session(items))
    return rep


def test_reporter_records_passing_call(tmp_path: Path) -> None:
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="setup", passed=True, duration=0.001))
    rep.pytest_runtest_logreport(_report(when="call", passed=True, duration=0.05))
    rep.pytest_runtest_logreport(_report(when="teardown", passed=True, duration=0.002))
    rep.pytest_sessionfinish(_fake_session(), 0)
    # `time` sums all three phases (1 + 50 + 2 ms).
    assert json.loads(out.read_text()) == [_expected_result(time=53)]


def test_reporter_sub_ms_durations_sum_before_rounding(tmp_path: Path) -> None:
    """Three sub-ms phases each round to 0 if rounded per-phase; the
    reporter accumulates seconds and rounds once at emit so the real
    sum survives."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="setup", passed=True, duration=0.0006))
    rep.pytest_runtest_logreport(_report(when="call", passed=True, duration=0.0006))
    rep.pytest_runtest_logreport(_report(when="teardown", passed=True, duration=0.0006))
    rep.pytest_sessionfinish(_fake_session(), 0)
    # 0.0018s == 1.8ms; rounds to 2, not 0.
    assert json.loads(out.read_text())[0]["time"] == 2


def test_reporter_call_failure_is_FAILURE_with_stacktrace(tmp_path: Path) -> None:
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="call", failed=True, longrepr="boom traceback", duration=0.01)
    )
    rep.pytest_sessionfinish(_fake_session(), 1)
    assert json.loads(out.read_text()) == [
        _expected_result(
            type="FAILURE",
            time=10,
            message="boom traceback",
            stacktrace="boom traceback",
        )
    ]


def test_reporter_setup_failure_is_aborted(tmp_path: Path) -> None:
    """Setup-phase failure is ABORTED -- the test harness broke, not the test."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="setup", failed=True, longrepr="fixture exploded")
    )
    # Internal status distinguishes ABORTED from FAILED; both currently map
    # to the wire string "FAILURE" but the distinction matters if tpx ever
    # splits the two.
    assert rep._records["a.py::test_x"].status == tpx_pytest_bridge._STATUS_ABORTED
    rep.pytest_sessionfinish(_fake_session(), 1)
    assert json.loads(out.read_text()) == [
        _expected_result(
            type="FAILURE",
            message="fixture exploded",
            stacktrace="fixture exploded",
        )
    ]


def test_reporter_call_failure_is_failed_not_aborted(tmp_path: Path) -> None:
    """Call-phase failure uses FAILED, distinct from ABORTED."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="call", failed=True, longrepr="assertion failed")
    )
    assert rep._records["a.py::test_x"].status == tpx_pytest_bridge._STATUS_FAILED


def test_reporter_teardown_failure_after_pass_is_aborted(tmp_path: Path) -> None:
    """Teardown error after a passing call surfaces as ABORTED (harness), not FAILED (test)."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="setup", passed=True))
    rep.pytest_runtest_logreport(_report(when="call", passed=True))
    rep.pytest_runtest_logreport(
        _report(when="teardown", failed=True, longrepr="cleanup boom")
    )
    assert rep._records["a.py::test_x"].status == tpx_pytest_bridge._STATUS_ABORTED
    rep.pytest_sessionfinish(_fake_session(), 1)
    assert json.loads(out.read_text()) == [
        _expected_result(
            type="FAILURE",
            message="cleanup boom",
            stacktrace="cleanup boom",
        )
    ]


def test_reporter_teardown_failure_after_call_failure_stays_failed(
    tmp_path: Path,
) -> None:
    """A teardown error after a call failure must not demote FAILED to ABORTED."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="call", failed=True, longrepr="real failure")
    )
    rep.pytest_runtest_logreport(
        _report(when="teardown", failed=True, longrepr="teardown noise")
    )
    assert rep._records["a.py::test_x"].status == tpx_pytest_bridge._STATUS_FAILED


def test_reporter_first_stacktrace_wins(tmp_path: Path) -> None:
    """Teardown error after a call failure must not clobber the call's stacktrace.

    The call's traceback is the useful one; the teardown's is noise.
    Both messages are still recorded for completeness.
    """
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="call", failed=True, longrepr="original trace")
    )
    rep.pytest_runtest_logreport(
        _report(when="teardown", failed=True, longrepr="teardown trace")
    )
    rep.pytest_sessionfinish(_fake_session(), 1)
    assert json.loads(out.read_text()) == [
        _expected_result(
            type="FAILURE",
            message="original trace\nteardown trace",
            stacktrace="original trace",
        )
    ]


def test_reporter_skipped_uses_assumption_violation_with_skipif_reason(
    tmp_path: Path,
) -> None:
    """`skipif` markers yield a `(file, lineno, reason)` triple in longrepr."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="setup", skipped=True, longrepr=("a.py", 7, "needs-network"))
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(
            type="ASSUMPTION_VIOLATION",
            message="Skipped: needs-network",
        )
    ]


def test_reporter_skipped_with_string_longrepr(tmp_path: Path) -> None:
    """`pytest.skip(reason=...)` produces a string longrepr like `Skipped: ...`;
    the reporter strips the existing prefix so the wire message doesn't
    double-prefix."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="call", skipped=True, longrepr="Skipped: manual")
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(
            type="ASSUMPTION_VIOLATION",
            message="Skipped: manual",
        )
    ]


def test_reporter_skipped_longrepr_without_existing_prefix(tmp_path: Path) -> None:
    """A string longrepr that doesn't start with `Skipped: ` gets the prefix added."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="call", skipped=True, longrepr="bare reason")
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(
            type="ASSUMPTION_VIOLATION",
            message="Skipped: bare reason",
        )
    ]


def test_reporter_skipped_no_reason_falls_back_to_bare_label(tmp_path: Path) -> None:
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="call", skipped=True, longrepr=None))
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(type="ASSUMPTION_VIOLATION", message="Skipped")
    ]


def test_reporter_skip_message_appended_even_if_status_already_set(
    tmp_path: Path,
) -> None:
    """Mirror of the xfail case: if setup/teardown already set a status, a
    plain skip report still contributes its reason to `message` rather than
    silently dropping it."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="setup", failed=True, longrepr="setup boom")
    )
    rep.pytest_runtest_logreport(
        _report(when="teardown", skipped=True, longrepr="Skipped: cleanup says no")
    )
    rep.pytest_sessionfinish(_fake_session(), 1)
    result = json.loads(out.read_text())[0]
    # Status stays ABORTED from setup; the skip reason still rides along in `message`.
    assert result["type"] == "FAILURE"
    assert "setup boom" in result["message"]
    assert "Skipped: cleanup says no" in result["message"]


def test_reporter_xfail_failed_as_expected_is_success(tmp_path: Path) -> None:
    """`xfail` test that fails reports skipped+wasxfail; should map to SUCCESS."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="call", skipped=True, wasxfail="reason"))
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(message="Expected failure: reason")
    ]


def test_reporter_xfail_message_appended_even_if_status_already_set(
    tmp_path: Path,
) -> None:
    """If setup/teardown already set a status, the xfail report still
    contributes its reason to `message` -- losing it would silently drop
    information from the wire output."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="setup", failed=True, longrepr="setup boom")
    )
    rep.pytest_runtest_logreport(_report(when="call", skipped=True, wasxfail="reason"))
    rep.pytest_sessionfinish(_fake_session(), 1)
    result = json.loads(out.read_text())[0]
    # Status stays ABORTED from setup; the xfail reason still rides along in `message`.
    assert result["type"] == "FAILURE"
    assert "setup boom" in result["message"]
    assert "Expected failure: reason" in result["message"]


def test_reporter_xfail_after_setup_pass_sets_expected_failure(
    tmp_path: Path,
) -> None:
    """Setup-pass then call-skipped+wasxfail must still land on
    `_STATUS_EXPECTED_FAILURE` -- symmetric with the setup-failed case
    covered above, but exercising the happy `rec.status is None` branch
    after a passing setup phase.
    """
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="setup", passed=True))
    rep.pytest_runtest_logreport(_report(when="call", skipped=True, wasxfail="reason"))
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(message="Expected failure: reason")
    ]


def test_reporter_xfail_unexpected_pass_is_success(tmp_path: Path) -> None:
    """Non-strict xfail that unexpectedly passes reports passed+wasxfail;
    mirrors pytest's own non-strict behavior (XPASS doesn't fail the run)
    while still surfacing the annotation in `message`."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="call", passed=True, wasxfail="reason"))
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(type="SUCCESS", message="Unexpected success: reason")
    ]


def test_reporter_xfail_unexpected_pass_message_appended_even_if_status_already_set(
    tmp_path: Path,
) -> None:
    """Mirror of the expected-failure case: if setup/teardown already set a
    status, the xfail-passes-unexpectedly report still contributes its
    annotation to `message` rather than silently dropping it."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="setup", failed=True, longrepr="setup boom")
    )
    rep.pytest_runtest_logreport(_report(when="call", passed=True, wasxfail="reason"))
    rep.pytest_sessionfinish(_fake_session(), 1)
    result = json.loads(out.read_text())[0]
    # Status stays ABORTED from setup; the xfail annotation still rides along in `message`.
    assert result["type"] == "FAILURE"
    assert "setup boom" in result["message"]
    assert "Unexpected success: reason" in result["message"]


def test_reporter_emits_results_in_collection_order(tmp_path: Path) -> None:
    """Results follow collection order, not logreport order; orphan
    collection-failure records come after item-backed records."""
    items = [
        _fake_item(nodeid="a.py::test_a", name="test_a", module_name="a"),
        _fake_item(nodeid="b.py::test_b", name="test_b", module_name="b"),
        _fake_item(nodeid="c.py::test_c", name="test_c", module_name="c"),
    ]
    out = tmp_path / "r.json"
    rep = _reporter_with_items(items, str(out))
    # Reports arrive out of collection order; b before a before c.
    rep.pytest_runtest_logreport(_report(nodeid="b.py::test_b", passed=True))
    rep.pytest_runtest_logreport(_report(nodeid="a.py::test_a", passed=True))
    rep.pytest_runtest_logreport(_report(nodeid="c.py::test_c", passed=True))
    # Plus an orphan collection error.
    rep.pytest_collectreport(
        _report(nodeid="z.py", failed=True, longrepr="import error")
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    results = json.loads(out.read_text())
    assert [r["testCase"] for r in results] == [
        "test_a",
        "test_b",
        "test_c",
        "<collection error>",
    ]


def test_reporter_collection_failure_creates_record_without_item(
    tmp_path: Path,
) -> None:
    """Collection errors fire before items exist; the reporter must still surface them."""
    out = tmp_path / "r.json"
    rep = _reporter_with_items([], str(out))
    rep.pytest_collectreport(
        _report(nodeid="pkg/test_broken.py", failed=True, longrepr="import error")
    )
    rep.pytest_sessionfinish(_fake_session(), 1)
    assert json.loads(out.read_text()) == [
        _expected_result(
            testCaseName="pkg.test_broken",
            testCase="<collection error>",
            type="FAILURE",
            message="import error",
            stacktrace="import error",
        )
    ]


def test_reporter_collection_failure_preserves_subnode_locator(
    tmp_path: Path,
) -> None:
    """If a collection error fires with a `::`-qualified nodeid (e.g. a class
    or function within a module), preserve the subnode in `testCase` rather
    than collapsing to the bare `<collection error>` sentinel -- the locator
    helps the engineer find the failure."""
    out = tmp_path / "r.json"
    rep = _reporter_with_items([], str(out))
    rep.pytest_collectreport(
        _report(nodeid="pkg/test_broken.py::SomeClass", failed=True, longrepr="boom")
    )
    rep.pytest_sessionfinish(_fake_session(), 1)
    assert json.loads(out.read_text()) == [
        _expected_result(
            testCaseName="pkg.test_broken",
            testCase="SomeClass",
            type="FAILURE",
            message="boom",
            stacktrace="boom",
        )
    ]


def test_reporter_collection_failure_records_output_and_duration(
    tmp_path: Path,
) -> None:
    """Import-time prints and duration on a collect-phase failure must
    reach tpx's stdOut/stdErr/time fields rather than being dropped."""
    out = tmp_path / "r.json"
    rep = _reporter_with_items([], str(out))
    rep.pytest_collectreport(
        _report(
            nodeid="pkg/test_broken.py",
            failed=True,
            longrepr="boom",
            capstdout="loud-import\n",
            capstderr="loud-warning\n",
            duration=0.012,
        )
    )
    rep.pytest_sessionfinish(_fake_session(), 1)
    assert json.loads(out.read_text()) == [
        _expected_result(
            testCaseName="pkg.test_broken",
            testCase="<collection error>",
            type="FAILURE",
            time=12,
            message="boom",
            stacktrace="boom",
            stdOut="loud-import\n",
            stdErr="loud-warning\n",
        )
    ]


def test_reporter_collection_failure_without_longrepr(tmp_path: Path) -> None:
    out = tmp_path / "r.json"
    rep = _reporter_with_items([], str(out))
    rep.pytest_collectreport(
        _report(nodeid="pkg/test_broken.py", failed=True, longrepr=None)
    )
    rep.pytest_sessionfinish(_fake_session(), 1)
    assert json.loads(out.read_text()) == [
        _expected_result(
            testCaseName="pkg.test_broken",
            testCase="<collection error>",
            type="FAILURE",
            message="Collection failed: pkg/test_broken.py",
        )
    ]


def test_reporter_collectreport_failure_beats_later_skip(tmp_path: Path) -> None:
    """If pytest fires both a failed and a skipped collect report for the
    same nodeid (rare but possible with nested collectors), the failure
    must win -- a later skip report must not downgrade the status. Mirror
    of the call-vs-teardown precedence rule in the runtest path."""
    out = tmp_path / "r.json"
    rep = _reporter_with_items([], str(out))
    rep.pytest_collectreport(
        _report(nodeid="pkg/test_broken.py", failed=True, longrepr="boom")
    )
    rep.pytest_collectreport(
        _report(
            nodeid="pkg/test_broken.py",
            failed=False,
            skipped=True,
            longrepr="Skipped: irrelevant",
        )
    )
    assert (
        rep._records["pkg/test_broken.py"].status == tpx_pytest_bridge._STATUS_ABORTED
    )
    rep.pytest_sessionfinish(_fake_session(), 1)
    result = json.loads(out.read_text())[0]
    # Status stays FAILURE (ABORTED maps to FAILURE on the wire); the skip
    # reason still rides along in `message` rather than being dropped.
    assert result["type"] == "FAILURE"
    assert "boom" in result["message"]
    assert "Skipped: irrelevant" in result["message"]


def test_reporter_passing_collectreport_is_ignored(tmp_path: Path) -> None:
    out = tmp_path / "r.json"
    rep = _reporter_with_items([], str(out))
    rep.pytest_collectreport(
        _report(nodeid="pkg/test_ok.py", failed=False, longrepr=None)
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == []


def test_reporter_skipped_collectreport_with_string_reason(tmp_path: Path) -> None:
    """Module-level skip during collection (e.g. `pytest.skip(allow_module_level=True)`)
    surfaces as ASSUMPTION_VIOLATION rather than being silently dropped."""
    out = tmp_path / "r.json"
    rep = _reporter_with_items([], str(out))
    rep.pytest_collectreport(
        _report(
            nodeid="pkg/test_optional.py",
            failed=False,
            skipped=True,
            longrepr="Skipped: optional dep missing",
        )
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(
            testCaseName="pkg.test_optional",
            testCase="<collection skipped>",
            type="ASSUMPTION_VIOLATION",
            message="Skipped: optional dep missing",
        )
    ]


def test_reporter_skipped_collectreport_with_tuple_reason(tmp_path: Path) -> None:
    """A collection-level skipif renders the tuple form into a clean message."""
    out = tmp_path / "r.json"
    rep = _reporter_with_items([], str(out))
    rep.pytest_collectreport(
        _report(
            nodeid="pkg/test_optional.py",
            failed=False,
            skipped=True,
            longrepr=("pkg/test_optional.py", 3, "needs-network"),
        )
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(
            testCaseName="pkg.test_optional",
            testCase="<collection skipped>",
            type="ASSUMPTION_VIOLATION",
            message="Skipped: needs-network",
        )
    ]


def test_reporter_skipped_collectreport_without_longrepr(tmp_path: Path) -> None:
    out = tmp_path / "r.json"
    rep = _reporter_with_items([], str(out))
    rep.pytest_collectreport(
        _report(
            nodeid="pkg/test_optional.py",
            failed=False,
            skipped=True,
            longrepr=None,
        )
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(
            testCaseName="pkg.test_optional",
            testCase="<collection skipped>",
            type="ASSUMPTION_VIOLATION",
            message="Skipped",
        )
    ]


def test_reporter_emits_aborted_for_collected_items_with_no_logreport(
    tmp_path: Path,
) -> None:
    """An item collected but never reported on (session interrupt, `-x`
    early-exit, etc.) must surface as ABORTED rather than be silently
    dropped from the JSON."""
    items = [
        _fake_item(nodeid="a.py::test_ran", name="test_ran", module_name="a"),
        _fake_item(
            nodeid="b.py::test_skipped_run", name="test_skipped_run", module_name="b"
        ),
    ]
    out = tmp_path / "r.json"
    rep = _reporter_with_items(items, str(out))
    # Only the first item gets a logreport; the second was collected but
    # never executed.
    rep.pytest_runtest_logreport(_report(nodeid="a.py::test_ran", passed=True))
    rep.pytest_sessionfinish(_fake_session(), 1)
    # The unrun record carries default-empty fields (time/message/stacktrace),
    # not stale state from some other test.
    assert json.loads(out.read_text()) == [
        _expected_result(testCase="test_ran"),
        _expected_result(testCaseName="b", testCase="test_skipped_run", type="FAILURE"),
    ]


def test_reporter_accumulates_stdout_stderr(tmp_path: Path) -> None:
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(
            when="setup", passed=True, capstdout="setup-out\n", capstderr="setup-err\n"
        )
    )
    rep.pytest_runtest_logreport(
        _report(
            when="call", passed=True, capstdout="call-out\n", capstderr="call-err\n"
        )
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [
        _expected_result(
            stdOut="setup-out\ncall-out\n",
            stdErr="setup-err\ncall-err\n",
        )
    ]


def test_reporter_handles_none_capstdout(tmp_path: Path) -> None:
    """pytest sometimes emits None for capstdout/capstderr; treat as empty."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(
        _report(when="call", passed=True, capstdout=None, capstderr=None)
    )
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert json.loads(out.read_text()) == [_expected_result()]


def test_reporter_writes_atomically_via_temp_file(tmp_path: Path) -> None:
    """The reporter writes via `os.replace` so tpx never sees a partial
    file. Verify the destination ends up correct and no `.tmp` litter
    survives next to it.
    """
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="call", passed=True))
    rep.pytest_sessionfinish(_fake_session(), 0)
    assert out.exists()
    # No leftover `.tmp` siblings from a successful write -- the rename
    # consumed them.
    leftovers = list(tmp_path.glob(".tpx_pytest_bridge.*"))
    assert leftovers == [], f"unexpected temp files: {leftovers}"


def test_reporter_cleans_up_temp_file_on_dump_failure(
    tmp_path: Path, monkeypatch: MonkeyPatch
) -> None:
    """If `json.dump` raises (e.g. unserialisable record), the temp file
    must be cleaned up and the destination left untouched."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="call", passed=True))

    def boom(*_args: Any, **_kwargs: Any) -> None:
        raise RuntimeError("disk full")

    monkeypatch.setattr(tpx_pytest_bridge.json, "dump", boom)
    with pytest.raises(RuntimeError, match="disk full"):
        rep.pytest_sessionfinish(_fake_session(), 0)
    assert not out.exists()
    leftovers = list(tmp_path.glob(".tpx_pytest_bridge.*"))
    assert leftovers == [], f"temp file leaked: {leftovers}"


def test_reporter_json_is_pretty_and_sorted(tmp_path: Path) -> None:
    """tpx tolerates any well-formed JSON; pretty+sorted output makes the
    file diff-friendly for humans inspecting failures locally."""
    item = _fake_item(nodeid="a.py::test_x", name="test_x", module_name="a")
    out = tmp_path / "r.json"
    rep = _reporter_with_items([item], str(out))
    rep.pytest_runtest_logreport(_report(when="call", passed=True))
    rep.pytest_sessionfinish(_fake_session(), 0)
    text = out.read_text()
    # Indented (so newline before key) and sorted (testCase before type).
    assert '"testCase":' in text
    assert text.index('"testCase":') < text.index('"type":')
    assert "\n" in text  # not collapsed onto one line


# --- main() -----------------------------------------------------------------


def _patch_tpx_pytest_bridge(
    monkeypatch: MonkeyPatch,
    *,
    pytest_exit_code: int = 0,
) -> dict[str, Any]:
    """Replace `pytest.main` with a stub; return a dict that captures the args it was called with.

    Lets `main()` tests assert on what pytest *would* have been invoked
    with, without actually re-entering a pytest session.

    Also stubs `_is_importable` to always return True. Most `main()` tests
    use placeholder dotted names like `pkg.test_foo` that don't resolve on
    `sys.path`; without this stub the importability filter would short-
    circuit and never reach the stubbed `pytest.main`. Tests that
    specifically exercise the importability filter override this via
    `_patch_importable` (the later `monkeypatch.setattr` wins).
    """
    captured: dict[str, Any] = {}

    def fake_tpx_pytest_bridge(argv: list[str], plugins: list[Any]) -> int:
        captured["argv"] = argv
        captured["plugins"] = plugins
        return pytest_exit_code

    monkeypatch.setattr(tpx_pytest_bridge.pytest, "main", fake_tpx_pytest_bridge)
    monkeypatch.setattr(tpx_pytest_bridge, "_is_importable", lambda _m: True)
    return captured


def test_main_no_test_modules_returns_failure(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    _patch_tpx_pytest_bridge(monkeypatch)
    assert tpx_pytest_bridge.main([], ["pkg.helpers"]) == 70
    assert "no test modules found" in capsys.readouterr().err


def test_main_no_test_modules_in_list_mode_returns_success(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    """`--list-tests` against a target with no test sources is empty, not broken."""
    _patch_tpx_pytest_bridge(monkeypatch)
    assert tpx_pytest_bridge.main(["--list-tests"], ["pkg.helpers"]) == 0
    # Still warns on stderr so a human can spot a misconfigured target.
    assert "no test modules found" in capsys.readouterr().err


def test_main_regex_no_match_returns_success(monkeypatch: MonkeyPatch) -> None:
    """pytest exit 5 (no tests collected) under `--regex` is the expected
    outcome when a user-supplied pattern filters everything."""
    _patch_tpx_pytest_bridge(monkeypatch, pytest_exit_code=5)
    assert tpx_pytest_bridge.main(["--regex", "no-match"], ["pkg.test_foo"]) == 0


def test_main_empty_regex_pytest_exit_5_is_failure(monkeypatch: MonkeyPatch) -> None:
    """`--regex ""` is functionally identical to no filter; an exit-5 result
    is then a real "no tests collected" misconfig, not a user-applied filter
    that happened to deselect everything. The truthy check at the exit-code
    mapping (and the symmetric one at plugin install) treats it that way."""
    _patch_tpx_pytest_bridge(monkeypatch, pytest_exit_code=5)
    assert tpx_pytest_bridge.main(["--regex", ""], ["pkg.test_foo"]) == 70


def test_main_empty_regex_does_not_install_filter_plugin(
    monkeypatch: MonkeyPatch,
) -> None:
    """Symmetric with the exit-5 mapping: `--regex ""` is no filter, so don't
    install a no-op plugin either."""
    captured = _patch_tpx_pytest_bridge(monkeypatch)
    tpx_pytest_bridge.main(["--regex", ""], ["pkg.test_foo"])
    assert not any(
        isinstance(p, tpx_pytest_bridge._RegexFilterPlugin) for p in captured["plugins"]
    )


def test_main_list_regex_no_match_returns_success(monkeypatch: MonkeyPatch) -> None:
    """`--list-tests --regex <no-match>` is success too -- the user asked
    for a filtered enumeration and got an empty one."""
    _patch_tpx_pytest_bridge(monkeypatch, pytest_exit_code=5)
    assert (
        tpx_pytest_bridge.main(
            ["--list-tests", "--regex", "no-match"], ["pkg.test_foo"]
        )
        == 0
    )


def test_main_list_without_regex_no_tests_returns_success(
    monkeypatch: MonkeyPatch,
) -> None:
    """`--list-tests` on a test-named module with no test functions yields
    pytest exit 5; treat the empty enumeration as success, not a failure."""
    _patch_tpx_pytest_bridge(monkeypatch, pytest_exit_code=5)
    assert tpx_pytest_bridge.main(["--list-tests"], ["pkg.test_foo"]) == 0


def test_main_pytest_exit_5_without_regex_is_failure(monkeypatch: MonkeyPatch) -> None:
    """Without `--regex`, `--list-tests`, or any pytest passthrough,
    exit 5 means a real "no tests" misconfiguration."""
    _patch_tpx_pytest_bridge(monkeypatch, pytest_exit_code=5)
    assert tpx_pytest_bridge.main([], ["pkg.test_foo"]) == 70


def test_main_pytest_exit_5_with_passthrough_is_success(
    monkeypatch: MonkeyPatch,
) -> None:
    """A user-supplied pytest filter (e.g. `-k pat`) that deselects every
    test still exits 5; the bridge treats this as "did what you asked"
    rather than a target misconfiguration, so `buck2 run :test -- -k nope`
    doesn't surface as a test failure."""
    _patch_tpx_pytest_bridge(monkeypatch, pytest_exit_code=5)
    assert tpx_pytest_bridge.main(["-k", "nope"], ["pkg.test_foo"]) == 0


def test_main_pytest_success_maps_to_zero(monkeypatch: MonkeyPatch) -> None:
    _patch_tpx_pytest_bridge(monkeypatch, pytest_exit_code=0)
    assert tpx_pytest_bridge.main([], ["pkg.test_foo"]) == 0


def test_main_pytest_failure_maps_to_seventy(monkeypatch: MonkeyPatch) -> None:
    _patch_tpx_pytest_bridge(monkeypatch, pytest_exit_code=1)
    assert tpx_pytest_bridge.main([], ["pkg.test_foo"]) == 70


def test_main_passes_pytest_args_through(monkeypatch: MonkeyPatch) -> None:
    captured = _patch_tpx_pytest_bridge(monkeypatch)
    tpx_pytest_bridge.main(["-k", "pattern", "-x"], ["pkg.test_foo"])
    assert "-k" in captured["argv"]
    assert "pattern" in captured["argv"]
    assert "-x" in captured["argv"]
    # And the expected base args are still present.
    assert "--pyargs" in captured["argv"]
    assert "pkg.test_foo" in captured["argv"]
    # Cache provider is always disabled.
    assert "no:cacheprovider" in captured["argv"]


def test_main_filters_non_test_modules_from_pyargs(monkeypatch: MonkeyPatch) -> None:
    captured = _patch_tpx_pytest_bridge(monkeypatch)
    tpx_pytest_bridge.main([], ["pkg.test_foo", "pkg.helpers", "pkg.bar_test"])
    # Helpers module (not a test) is filtered out; the two test modules stay.
    assert "pkg.test_foo" in captured["argv"]
    assert "pkg.bar_test" in captured["argv"]
    assert "pkg.helpers" not in captured["argv"]


def test_main_warns_about_filtered_non_test_modules(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    """Non-test srcs are listed on stderr so a misconfigured target is visible."""
    _patch_tpx_pytest_bridge(monkeypatch)
    tpx_pytest_bridge.main([], ["pkg.test_foo", "pkg.helpers", "pkg.utils"])
    err = capsys.readouterr().err
    assert "ignoring non-test src(s)" in err
    assert "pkg.helpers" in err
    assert "pkg.utils" in err
    # Real test module should not appear in the warning.
    assert "pkg.test_foo" not in err


def test_main_no_warning_when_all_srcs_are_tests(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    _patch_tpx_pytest_bridge(monkeypatch)
    tpx_pytest_bridge.main([], ["pkg.test_foo", "pkg.bar_test"])
    assert "ignoring non-test src(s)" not in capsys.readouterr().err


def test_main_invalid_regex_returns_failure_with_message(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    """An invalid regex from `--regex` produces a friendly error, not a traceback."""
    _patch_tpx_pytest_bridge(monkeypatch)
    assert tpx_pytest_bridge.main(["--regex", "("], ["pkg.test_foo"]) == 70
    err = capsys.readouterr().err
    assert "invalid --regex" in err
    assert "'('" in err


def test_main_list_uses_collect_only_and_silences_terminal(
    monkeypatch: MonkeyPatch,
) -> None:
    captured = _patch_tpx_pytest_bridge(monkeypatch)
    assert tpx_pytest_bridge.main(["--list-tests"], ["pkg.test_foo"]) == 0
    assert "--collect-only" in captured["argv"]
    assert "no:terminal" in captured["argv"]
    assert any(
        isinstance(p, tpx_pytest_bridge._ListPlugin) for p in captured["plugins"]
    )


def test_main_list_with_output_warns_about_ignored_arg(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str], tmp_path: Path
) -> None:
    _patch_tpx_pytest_bridge(monkeypatch)
    tpx_pytest_bridge.main(
        ["--list-tests", "--output", str(tmp_path / "r.json")], ["pkg.test_foo"]
    )
    assert "--output is ignored" in capsys.readouterr().err


def test_main_output_adds_json_reporter_plugin(
    monkeypatch: MonkeyPatch, tmp_path: Path
) -> None:
    captured = _patch_tpx_pytest_bridge(monkeypatch)
    tpx_pytest_bridge.main(["--output", str(tmp_path / "r.json")], ["pkg.test_foo"])
    assert any(
        isinstance(p, tpx_pytest_bridge._BuckJsonReporter) for p in captured["plugins"]
    )


def test_main_regex_adds_filter_plugin(monkeypatch: MonkeyPatch) -> None:
    captured = _patch_tpx_pytest_bridge(monkeypatch)
    tpx_pytest_bridge.main(["--regex", "x"], ["pkg.test_foo"])
    assert any(
        isinstance(p, tpx_pytest_bridge._RegexFilterPlugin) for p in captured["plugins"]
    )


def test_main_no_regex_means_no_filter_plugin(monkeypatch: MonkeyPatch) -> None:
    captured = _patch_tpx_pytest_bridge(monkeypatch)
    tpx_pytest_bridge.main([], ["pkg.test_foo"])
    assert not any(
        isinstance(p, tpx_pytest_bridge._RegexFilterPlugin) for p in captured["plugins"]
    )


# --- Unimportable-module handling ------------------------------------------


def _patch_importable(monkeypatch: MonkeyPatch, importable: set[str]) -> None:
    """Stub `_is_importable` to treat only names in `importable` as findable."""
    monkeypatch.setattr(tpx_pytest_bridge, "_is_importable", lambda m: m in importable)


def test_main_unimportable_modules_hard_error(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    """An unimportable test-named src is a hard error: pytest's `--pyargs`
    would silently drop it, and tpx/buck2 don't reliably surface stderr
    from a passing run, so filtering-and-continuing would let coverage
    silently disappear. Bail with non-zero and a clear message instead."""
    captured = _patch_tpx_pytest_bridge(monkeypatch)
    _patch_importable(monkeypatch, importable={"pkg.test_real"})
    assert tpx_pytest_bridge.main([], ["pkg.test_real", "pkg.test_fake"]) == 70
    # We bail before invoking pytest, so the captured argv is untouched.
    assert "argv" not in captured
    err = capsys.readouterr().err
    assert "unimportable test module(s)" in err
    assert "pkg.test_fake" in err
    # Importable module should not appear in the error.
    assert "pkg.test_real" not in err


def test_main_all_unimportable_returns_failure(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    """When every test-named src is unimportable, the bridge bails before
    pytest with the unimportable-module error rather than handing pytest
    an empty `--pyargs` list."""
    _patch_tpx_pytest_bridge(monkeypatch)
    _patch_importable(monkeypatch, importable=set())
    assert tpx_pytest_bridge.main([], ["pkg.test_fake"]) == 70
    assert "unimportable test module(s)" in capsys.readouterr().err


def test_main_unimportable_in_list_mode_is_hard_error(
    monkeypatch: MonkeyPatch,
) -> None:
    """List mode bails too: tpx enumerates via `--list-tests` first, so a
    silently-dropped src would be invisible for the rest of the run."""
    _patch_tpx_pytest_bridge(monkeypatch)
    _patch_importable(monkeypatch, importable=set())
    assert tpx_pytest_bridge.main(["--list-tests"], ["pkg.test_fake"]) == 70


def test_main_no_error_when_all_modules_importable(
    monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    _patch_tpx_pytest_bridge(monkeypatch)
    _patch_importable(monkeypatch, importable={"pkg.test_a", "pkg.test_b"})
    tpx_pytest_bridge.main([], ["pkg.test_a", "pkg.test_b"])
    assert "unimportable test module(s)" not in capsys.readouterr().err


# --- _is_importable --------------------------------------------------------


def test_is_importable_true_for_real_module() -> None:
    # `json` is in the stdlib; should always be locatable.
    assert tpx_pytest_bridge._is_importable("json") is True


def test_is_importable_false_for_missing_module() -> None:
    assert tpx_pytest_bridge._is_importable("this_module_does_not_exist_xyz") is False


def test_is_importable_false_for_missing_parent_package() -> None:
    """`find_spec("nope.also_nope")` raises `ModuleNotFoundError` (subclass of
    `ImportError`) because the parent package can't be located; the helper
    catches that and reports unimportable rather than propagating."""
    assert tpx_pytest_bridge._is_importable("nope_pkg_xyz.test_inner") is False


def test_is_importable_false_for_arbitrary_parent_exception(
    monkeypatch: MonkeyPatch,
) -> None:
    """A parent `__init__.py` that raises something other than `ImportError`
    during its top-level execution (e.g. a broken module that raises
    `RuntimeError` at import time) must be reported as unimportable rather
    than crashing the bridge before pytest gets a chance to run."""

    def boom(_name: str, _package: str | None = None) -> None:
        raise RuntimeError("broken parent __init__.py")

    monkeypatch.setattr(tpx_pytest_bridge.importlib.util, "find_spec", boom)
    assert tpx_pytest_bridge._is_importable("anything") is False
