# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Buck2 `python_test` entrypoint that runs pytest.

Replaces the default `__test_main__` runner (which uses unittest discovery)
so tests can be written in pytest style — fixtures, plain
`def test_…(): assert …` functions, parametrize, `pytest.raises`.

Normally you don't reference this module directly — use the `pytest()`
macro from `//third_party/python/pytest:pytest.bzl`, which wires `main_module` and
`deps` for you.

The buck2 `python_test` rule generates `__test_modules__.TEST_MODULES`,
the dotted-path list of every `srcs` entry in the target. We filter to
modules matching pytest's default discovery (`test_*` prefix or `*_test`
suffix); non-test srcs are warned about on stderr but the run continues
with the test-named ones. A test-named src that isn't importable from
the PAR's `sys.path` is a hard error -- pytest's `--pyargs` would
otherwise silently drop it, and tpx and the buck2 internal runner don't
reliably surface stderr from a passing run, so the dropped src would
look indistinguishable from "test passed". We'd rather fail loudly
than ship a "green" target that is missing coverage.

# Buck2/tpx test protocol

This module implements the subset of `prelude/python/tools/__test_main__.py`'s
CLI that buck2's test runner (tpx) uses to enumerate and report results:

  --list-tests / --list-format   enumerate collected tests, one per line
  --output PATH                  write per-test results as JSON to PATH
  --regex REGEX                  filter to tests whose buck id matches REGEX

Note: `--regex ""` is treated as if the flag were not passed -- "match
everything" is indistinguishable from "no filter", and treating the empty
case as a user-supplied filter would mask a real "no tests collected"
misconfiguration when `pytest` exits 5. Use `--regex .` if you specifically
want the match-everything semantic.

Unknown args are forwarded to pytest as-is, so
`buck2 run //path:test -- -k pattern -x` works. Caveat: because the
bridge invokes pytest with `--pyargs`, any *positional* passthrough is
interpreted as a dotted module name -- `buck2 run :test -- path/to/extra_test.py`
will fail with `ModuleNotFoundError`, not collect the file. Stick to
flag-style passthrough (`-k`, `-m`, `-x`, `--lf`, etc); the modules-under-test
list is determined by `srcs` on the buck target, not by command-line paths.
"""

import argparse
import importlib.util
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from typing import Any, Protocol, TypedDict

import pytest


# Status strings mirror `TestStatus` in `prelude/python/tools/__test_main__.py`
# so tpx parses our JSON the same way it parses the prelude runner's.
_STATUS_PASSED: str = "SUCCESS"
_STATUS_FAILED: str = "FAILURE"
_STATUS_ABORTED: str = "FAILURE"
_STATUS_SKIPPED: str = "ASSUMPTION_VIOLATION"
_STATUS_EXPECTED_FAILURE: str = "SUCCESS"
# Mirrors pytest's non-strict XPASS semantics: an unexpected pass doesn't
# fail the run, just annotates the result. (Strict-mode unexpected passes
# arrive as `failed=True` and go through the standard failure path.)
_STATUS_UNEXPECTED_SUCCESS: str = "SUCCESS"

# Exit codes mirror prelude's runner: 0 on success, 70 on any failure.
_EXIT_CODE_SUCCESS: int = 0
_EXIT_CODE_TEST_FAILURE: int = 70


# --- Pytest interface protocols ---------------------------------------------
#
# Structural types covering the attributes we touch on pytest's `Item`,
# `TestReport` / `CollectReport`, and `Session`. Lets pyright catch typos
# without making this module depend on pytest's type stubs.


class _PytestModule(Protocol):
    __name__: str


class _PytestItem(Protocol):
    nodeid: str
    name: str
    module: _PytestModule | None
    cls: type | None


class _PytestReport(Protocol):
    nodeid: str
    failed: bool
    passed: bool
    skipped: bool
    when: str
    duration: float | None
    capstdout: str | None
    capstderr: str | None
    # `longrepr` is heterogeneous: ExceptionInfo for failures, a
    # `(file, lineno, reason)` tuple for skipif, a string for
    # `pytest.skip(...)`, or None. Callers either str() it or unpack
    # the tuple form, so Any is the honest type here.
    longrepr: Any


class _PytestSession(Protocol):
    items: list[_PytestItem]


# --- Record / output types --------------------------------------------------


@dataclass
class _Record:
    """Per-test accumulator across setup/call/teardown phases.

    One `_Record` per nodeid; `_BuckJsonReporter.pytest_sessionfinish`
    folds these into the JSON list tpx reads.
    """

    messages: list[str] = field(default_factory=list)
    stacktrace: str | None = None
    stdout: str = ""
    stderr: str = ""
    status: str | None = None
    # Accumulate seconds as float; round to ms once at emit time so we
    # don't lose sub-ms precision per-phase.
    duration_s: float = 0.0


class _TpxResult(TypedDict):
    """Shape of one entry in the JSON list tpx reads.

    Field names are camelCase to match the prelude runner's wire format.
    """

    testCaseName: str
    testCase: str
    type: str
    time: int
    message: str
    stacktrace: str | None
    stdOut: str
    stdErr: str


def _is_test_module(dotted: str) -> bool:
    last = dotted.rsplit(".", 1)[-1]
    return last.startswith("test_") or last.endswith("_test")


def _is_importable(dotted: str) -> bool:
    """Check whether `dotted` can be located on `sys.path`.

    Uses `importlib.util.find_spec` so the target module's own top-level
    code isn't executed here -- pytest will re-run it when it imports
    the module via `--pyargs`. Note that locating a submodule does
    import its parent packages (so a broken parent `__init__.py` will
    run as a side effect of probing the child); we treat any failure to
    locate -- `ImportError` from a missing parent, `ValueError` from a
    relative-import style name, or any other exception raised by a
    parent's import -- as "not importable" rather than letting it crash
    the bridge before pytest gets to run.

    A module that locates fine but raises at import time will still be
    reported here as importable -- pytest's collection error path handles
    that case via `pytest_collectreport`, surfacing the real exception
    rather than a misleading "no module" warning. The asymmetry: a broken
    *child* gets reported with its real traceback by pytest, but a broken
    *parent* `__init__.py` fails the `find_spec` probe and is swallowed
    here, so the user only sees the "unimportable test module" stderr
    line. The unimportable warning message points at this case so debugging
    isn't misdirected toward `sys.path`.
    """
    try:
        return importlib.util.find_spec(dotted) is not None
    except Exception:
        return False


def _nodeid_to_module(nodeid: str) -> str:
    """Convert a nodeid file path like `pkg/test_foo.py` to dotted form.

    Used as a fallback when pytest hasn't attached a `module` to the
    item/report (e.g. collection errors fire before `item.module` is set).
    """
    path = nodeid.split("::", 1)[0]
    if path.endswith(".py"):
        path = path[:-3]
    return path.replace("/", ".").replace("\\", ".")


def _test_case_name(item: _PytestItem, *, use_qualname: bool = False) -> str:
    """Render `module.ClassName`; collapses to module when no class.

    When `use_qualname` is True, nested classes render as `Outer.Inner`
    rather than just `Inner`. Prelude uses `__qualname__` for the
    python-format `--list-tests` output but `__name__` for the JSON
    `testCaseName` and the buck-format id, so callers must pick.
    """
    module_name = (
        item.module.__name__
        if item.module is not None
        else _nodeid_to_module(item.nodeid)
    )
    if item.cls is not None:
        cls_name = item.cls.__qualname__ if use_qualname else item.cls.__name__
        return f"{module_name}.{cls_name}"
    return module_name


def _buck_test_id(item: _PytestItem) -> str:
    """`module.ClassName#test_name` -- the format prelude emits via `--list-format=buck`."""
    return f"{_test_case_name(item)}#{item.name}"


def _extract_skip_reason(longrepr: Any) -> str:
    """Pull the human-readable reason out of a skip's `longrepr`.

    `skipif` markers produce a `(file, lineno, reason)` tuple;
    `pytest.skip(reason=...)` produces a string like `"Skipped: ..."` --
    strip that prefix so callers don't render `"Skipped: Skipped: ..."`.
    Returns `""` when `longrepr` is None or doesn't carry a reason.

    The tuple branch takes the last element rather than indexing at `[2]`,
    so a future pytest format change (2-tuple, 4-tuple) still produces a
    sensible message instead of rendering the whole `repr` of the tuple.
    An empty tuple yields `""` rather than falling through to `str(())` ==
    `"()"`, which would otherwise surface as a meaningless skip reason.
    """
    if isinstance(longrepr, tuple):
        return str(longrepr[-1]) if longrepr else ""
    if longrepr is not None:
        text = str(longrepr)
        if text.startswith("Skipped: "):
            return text[len("Skipped: ") :]
        return text
    return ""


class _ListPlugin:
    """Print collected tests, one per line, in the requested format."""

    def __init__(self, list_format: str) -> None:
        self.list_format = list_format

    def pytest_collection_finish(self, session: _PytestSession) -> None:
        for item in session.items:
            if self.list_format == "buck":
                print(_buck_test_id(item))
            else:
                print(f"{item.name} ({_test_case_name(item, use_qualname=True)})")


class _RegexFilterPlugin:
    """Drop collected items whose buck-format id doesn't match `pattern`."""

    def __init__(self, pattern: str) -> None:
        self._re = re.compile(pattern)

    def pytest_collection_modifyitems(self, items: list[_PytestItem]) -> None:
        items[:] = [i for i in items if self._re.search(_buck_test_id(i))]


class _BuckJsonReporter:
    """Collect pytest reports and emit JSON in the shape tpx consumes."""

    def __init__(self, output_path: str) -> None:
        self.output_path: str = output_path
        self._records: dict[str, _Record] = {}
        self._items: dict[str, _PytestItem] = {}

    def pytest_collection_finish(self, session: _PytestSession) -> None:
        for item in session.items:
            self._items[item.nodeid] = item

    def pytest_collectreport(self, report: _PytestReport) -> None:
        """Record module-level collection failures and skips.

        These fire instead of `pytest_runtest_logreport` when pytest can't
        even build the items list, so without this hook the JSON output
        would be `[]` despite a real failure or skip.
        """
        if not (report.failed or report.skipped):
            return
        rec = self._records.setdefault(report.nodeid, _Record())
        # Accumulate captured output and duration alongside the failure so
        # import-time prints (deprecation warnings, debug spew from a
        # misbehaving conftest) survive to tpx's stdOut/stdErr/time fields.
        rec.stdout += report.capstdout or ""
        rec.stderr += report.capstderr or ""
        rec.duration_s += report.duration or 0
        if report.failed:
            # Failure beats any prior skip status on the same nodeid -- if
            # pytest fires multiple collect reports for one nodeid (rare,
            # but possible with nested collectors), the more-severe outcome
            # wins. Symmetric with the call-vs-teardown rule in the
            # runtest path below.
            rec.status = _STATUS_ABORTED
            if report.longrepr is not None:
                detail = str(report.longrepr)
                if rec.stacktrace is None:
                    rec.stacktrace = detail
                rec.messages.append(detail)
            else:
                rec.messages.append(f"Collection failed: {report.nodeid}")
        else:
            # Module-level skip (e.g. `pytest.skip(allow_module_level=True)`
            # or a conftest-level skip during collection). No items will be
            # produced, so the JSON would otherwise omit the module entirely.
            # Don't downgrade a prior failure to a skip -- if a failure has
            # already been recorded for this nodeid, leave the status alone
            # and just append the skip reason so it survives in `message`.
            if rec.status != _STATUS_ABORTED:
                rec.status = _STATUS_SKIPPED
            reason = _extract_skip_reason(report.longrepr)
            rec.messages.append(f"Skipped: {reason}" if reason else "Skipped")

    def pytest_runtest_logreport(self, report: _PytestReport) -> None:
        rec = self._records.setdefault(report.nodeid, _Record())
        rec.stdout += report.capstdout or ""
        rec.stderr += report.capstderr or ""
        rec.duration_s += report.duration or 0

        # pytest sets `wasxfail` on the report when an `xfail`-marked test
        # fired its expectation: either failed as expected (surfaces as
        # `skipped`) or unexpectedly passed under `strict=False` (surfaces
        # as `passed`). The `strict=True` unexpected-pass case is a normal
        # `failed` report and falls through to the standard failure path.
        # `wasxfail` is dynamically added by pytest, so it's not in
        # `_PytestReport`; use getattr to honestly say "may be absent".
        wasxfail: str | None = getattr(report, "wasxfail", None)

        if report.failed:
            # Phase-aware: call-phase failure is FAILED (test logic broke);
            # setup/teardown failure is ABORTED (harness broke). A call
            # FAILED never gets demoted to ABORTED by a later teardown
            # error, so the more-informative status wins. Stacktrace is
            # only set on the first failure -- otherwise a teardown error
            # after a call failure would clobber the more useful trace.
            if report.when == "call":
                rec.status = _STATUS_FAILED
            elif rec.status != _STATUS_FAILED:
                rec.status = _STATUS_ABORTED
            if report.longrepr is not None:
                detail = str(report.longrepr)
                if rec.stacktrace is None:
                    rec.stacktrace = detail
                rec.messages.append(detail)
        elif report.skipped:
            if wasxfail is not None:
                # Always surface the xfail reason, even if a prior phase
                # already set a status -- the reason is information that
                # would otherwise be silently dropped.
                if rec.status is None:
                    rec.status = _STATUS_EXPECTED_FAILURE
                rec.messages.append(
                    f"Expected failure: {wasxfail}" if wasxfail else "Expected failure"
                )
            else:
                # Mirror the xfail branch: always surface the skip reason,
                # even if a prior phase already set a status -- otherwise
                # an explicit skip after a setup/teardown failure silently
                # drops the information. xfail-fail-as-expected is handled
                # above and never reaches this branch, so this is always an
                # explicit skip/skipif.
                if rec.status is None:
                    rec.status = _STATUS_SKIPPED
                reason = _extract_skip_reason(report.longrepr)
                rec.messages.append(f"Skipped: {reason}" if reason else "Skipped")
        elif report.when == "call" and report.passed:
            if wasxfail is not None:
                # Mirror the skipped+wasxfail branch: always surface the
                # annotation, even if a prior phase already set a status
                # -- otherwise an xfail-passes-unexpectedly after a
                # setup/teardown failure silently drops the information.
                if rec.status is None:
                    rec.status = _STATUS_UNEXPECTED_SUCCESS
                rec.messages.append(
                    f"Unexpected success: {wasxfail}"
                    if wasxfail
                    else "Unexpected success"
                )
            elif rec.status is None:
                rec.status = _STATUS_PASSED

    def pytest_sessionfinish(self, session: _PytestSession, exitstatus: int) -> None:
        del session, exitstatus  # required pytest hook signature; unused here
        # Emit in collection order so the JSON tracks `--list-tests` output;
        # orphan records (collection errors with no matching item) come last.
        # Items collected but lacking any logreport (e.g. session interrupt,
        # `-x` early-exit) still get a record so tpx sees an ABORTED entry
        # rather than a silently missing test.
        ordered_nodeids: list[str] = list(self._items)
        # Sort orphans by nodeid so the JSON is stable across runs regardless
        # of which hook fired first (collect-failures vs. unrun runtest
        # records can otherwise interleave in `_records` insertion order).
        orphan_nodeids: list[str] = sorted(
            nid for nid in self._records if nid not in self._items
        )
        results: list[_TpxResult] = []
        for nodeid in [*ordered_nodeids, *orphan_nodeids]:
            rec = self._records.get(nodeid) or _Record()
            item = self._items.get(nodeid)
            if item is not None:
                case_name = _test_case_name(item)
                case = item.name
            else:
                # `_records` may contain entries with no matching `_items`
                # entry (e.g. collection failures or skips recorded via
                # `pytest_collectreport`); synthesise a name from the
                # nodeid so tpx still sees the entry. The placeholder
                # reflects the actual status (failure vs. skip) so the
                # entry's testCase isn't misleading.
                case_name = _nodeid_to_module(nodeid)
                parts = nodeid.split("::")
                placeholder = (
                    "<collection skipped>"
                    if rec.status == _STATUS_SKIPPED
                    else "<collection error>"
                )
                case = "::".join(parts[1:]) or placeholder
            results.append(
                _TpxResult(
                    testCaseName=case_name,
                    testCase=case,
                    type=rec.status or _STATUS_ABORTED,
                    time=round(rec.duration_s * 1000),
                    message="\n".join(rec.messages),
                    stacktrace=rec.stacktrace,
                    stdOut=rec.stdout,
                    stdErr=rec.stderr,
                )
            )
        # Write to a sibling temp file and rename so tpx never observes a
        # partial file -- a crash mid-`json.dump` (signal, disk full, OOM)
        # would otherwise leave a truncated JSON that tpx reads as a parse
        # error. `os.replace` is atomic on POSIX and Windows.
        dir_path = os.path.dirname(self.output_path) or "."
        tmp = tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            prefix=".tpx_pytest_bridge.",
            suffix=".json.tmp",
            dir=dir_path,
            delete=False,
        )
        try:
            # The inner `with` closes the file before we rename or unlink
            # it, so the cleanup path works on Windows (which forbids
            # unlinking an open file) as well as POSIX.
            with tmp:
                json.dump(results, tmp, indent=4, sort_keys=True)
            os.replace(tmp.name, self.output_path)
        except BaseException:
            # On any failure, drop the temp file rather than leaving litter
            # next to the (still-untouched) output path.
            try:
                os.unlink(tmp.name)
            except OSError:
                pass
            raise


def _map_exit_code(pytest_code: int) -> int:
    """Map pytest's exit codes onto prelude's 0/70 convention.

    pytest distinguishes test failures (1), interrupt (2), internal error
    (3), usage error (4), and no-tests-collected (5); prelude only returns
    success (0) or failure (70). tpx reads the JSON file rather than the
    exit code, but keeping the same wire convention makes the two runners
    interchangeable for callers that do look at it.
    """
    return _EXIT_CODE_SUCCESS if pytest_code == 0 else _EXIT_CODE_TEST_FAILURE


def _parse_argv(argv: list[str]) -> tuple[argparse.Namespace, list[str]]:
    """Pull the buck/tpx flags out of argv; leave the rest for pytest.

    Only long forms are recognised -- pytest already uses `-l`
    (`--showlocals`), `-r` (summary), and `-o` (override ini) as short
    flags, so the corresponding short forms here would silently swallow
    pytest args passed via `buck2 run :test -- ...`.

    `allow_abbrev=False` disables argparse's prefix matching so a future
    pytest flag that shares a prefix with one of ours (e.g. a hypothetical
    `--regional-...`) doesn't get silently swallowed as `--regex`.
    """
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--list-tests", action="store_true", dest="list")
    parser.add_argument(
        "--list-format",
        choices=["buck", "python"],
        default="python",
    )
    parser.add_argument("--output", default=None)
    parser.add_argument("--regex", default=None)
    return parser.parse_known_args(argv)


def main(argv: list[str], test_modules: list[str]) -> int:
    """Run pytest over `test_modules`, translating buck/tpx flags from `argv`.

    `test_modules` is the dotted-path list buck2 synthesises as
    `__test_modules__.TEST_MODULES`; it's passed in (rather than imported
    here) so the runner can be exercised directly from a unittest target.
    `argv` is the post-program-name argument list (i.e. `sys.argv[1:]`).
    """
    args, passthrough = _parse_argv(argv)
    non_test_modules: list[str] = [m for m in test_modules if not _is_test_module(m)]
    if non_test_modules:
        # Surface filtered srcs so a misconfigured target (e.g. helpers
        # mistakenly placed in `srcs` instead of `deps`) is visible rather
        # than silently dropped from `--pyargs`.
        print(
            "third_party/python/pytest: ignoring non-test src(s) "
            f"(no `test_*` prefix or `*_test` suffix): "
            f"{', '.join(non_test_modules)}",
            file=sys.stderr,
        )
    runnable_modules: list[str] = [m for m in test_modules if _is_test_module(m)]
    if not runnable_modules:
        print(
            "third_party/python/pytest: no test modules found "
            "(expected `srcs` entries matching `test_*.py` or `*_test.py`)",
            file=sys.stderr,
        )
        # In listing mode, "no tests" is a valid empty result, not an error.
        return _EXIT_CODE_SUCCESS if args.list else _EXIT_CODE_TEST_FAILURE

    # Hard error on unimportable srcs: pytest's `--pyargs` silently drops
    # names it can't import (typically because the test file isn't under a
    # Python package on the PAR's `sys.path`, or a parent `__init__.py`
    # raises at import time), and neither tpx nor the buck2 internal
    # runner reliably surface a passing run's stderr -- so a silently-
    # dropped src would look identical to a passing run. We'd rather fail
    # loudly than ship a "green" target that is missing coverage.
    unimportable_modules: list[str] = [
        m for m in runnable_modules if not _is_importable(m)
    ]
    if unimportable_modules:
        print(
            "third_party/python/pytest: unimportable test module(s) "
            "(check that they live under a Python package on the PAR's `sys.path`, "
            "and that any parent `__init__.py` imports cleanly -- a parent that "
            "raises at import time will also surface here): "
            f"{', '.join(unimportable_modules)}",
            file=sys.stderr,
        )
        return _EXIT_CODE_TEST_FAILURE

    plugins: list[object] = []
    base_args: list[str] = ["-p", "no:cacheprovider", "--pyargs", *runnable_modules]

    # `--regex ""` is treated as "no filter applied" -- both the plugin
    # install and the exit-5 mapping below check truthiness, not `is not
    # None`, so an empty pattern doesn't mask a real "no tests collected"
    # misconfig. `_RegexFilterPlugin("")` with `re.search` still matches
    # every string if instantiated, so the plugin remains correct in
    # isolation (covered by tests).
    if args.regex:
        try:
            plugins.append(_RegexFilterPlugin(args.regex))
        except re.error as exc:
            print(
                f"third_party/python/pytest: invalid --regex {args.regex!r}: {exc}",
                file=sys.stderr,
            )
            return _EXIT_CODE_TEST_FAILURE

    if args.list:
        if args.output is not None:
            print(
                "third_party/python/pytest: --output is ignored when "
                "--list-tests is set",
                file=sys.stderr,
            )
        # `-p no:terminal` suppresses pytest's own summary so the only stdout
        # is the one-line-per-test output from `_ListPlugin`.
        plugins.append(_ListPlugin(args.list_format))
        exit_code = int(
            pytest.main(  # pyright: ignore[reportAttributeAccessIssue]
                ["--collect-only", "-p", "no:terminal", *base_args, *passthrough],
                plugins=plugins,
            )
        )
    else:
        if args.output is not None:
            plugins.append(_BuckJsonReporter(args.output))
        exit_code = int(
            pytest.main(  # pyright: ignore[reportAttributeAccessIssue]
                [*base_args, *passthrough], plugins=plugins
            )
        )

    # pytest exits 5 ("no tests collected") in three benign-for-us cases:
    #   * `--regex` filtered everything out -- the run did what was asked.
    #     tpx normally enumerates via `--list-tests` first so this is rare
    #     in production, but fires for `buck2 test :foo -- --regex <pat>`
    #     with a non-matching pattern. An empty `--regex ""` is excluded
    #     here (truthy check): it's functionally identical to no filter
    #     and would otherwise mask a real "no tests" misconfig.
    #   * `--list-tests` against a test-named module that happens to define
    #     no test functions -- an empty enumeration is a valid result.
    #   * Any pytest passthrough args supplied (e.g. `-k pat`, `-m mark`,
    #     `--deselect`) -- a user-supplied filter that deselects everything
    #     is a "did what you asked" outcome, not a misconfiguration. Without
    #     passthrough, exit 5 means a target genuinely has no tests, which
    #     is a real failure.
    if exit_code == 5 and (args.regex or args.list or passthrough):
        return _EXIT_CODE_SUCCESS
    return _map_exit_code(exit_code)


def _load_test_modules() -> list[str]:
    # `__test_modules__` is a synthesised top-level module emitted by buck2's
    # `python_test` rule; importing it outside a test PAR will fail, so the
    # import is deferred to the entry point rather than done at module scope.
    from __test_modules__ import TEST_MODULES  # type: ignore[import-not-found]

    return list(TEST_MODULES)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], _load_test_modules()))
