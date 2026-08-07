# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for the pytest bridge in `tpx_pytest_bridge`.

These drive `tpx_pytest_bridge.main` directly with synthesised test modules
and verify the return code and json are as intended.

This target is a plain `python_test` (unittest discovery), not a `pytest()`, so that we aren't relying on the system under test to work.
"""

import contextlib
import io
import json
import sys
import tempfile
import unittest
from collections.abc import Iterator
from pathlib import Path

from third_party.python.pytest import tpx_pytest_bridge

_PASSING: str = "def test_passes():\n    assert 1 + 1 == 2\n"
_FAILING: str = "def test_fails():\n    assert 1 + 1 == 3\n"
# Imports a module that doesn't exist, so pytest errors while collecting the
# module rather than while running any individual test.
_COLLECTION_ERROR: str = "import this_module_does_not_exist_xyz  # noqa: F401\n"
# A non-test name (no `test_` prefix / `_test` suffix); the bridge should
# filter this out before pytest ever sees it. The failing body would make
# the run fail if the filter let it through.
_DECOY: str = "def test_should_not_run():\n    assert False\n"
_SKIPPED: str = (
    "import pytest\n"
    "\n"
    '@pytest.mark.skip(reason="not today")\n'
    "def test_skips():\n"
    "    assert False\n"
)
# A `unittest.TestCase` so the bridge has to render `module.ClassName` +
# method name rather than a bare module-level function.
_CLASS_BASED: str = (
    "import unittest\n"
    "\n"
    "class TestThing(unittest.TestCase):\n"
    "    def test_method(self):\n"
    "        self.assertTrue(True)\n"
)
# Prints before failing so we can assert stdout capture flows into the JSON.
_FAILING_WITH_OUTPUT: str = (
    "def test_loud_fail():\n    print('marker-on-stdout')\n    assert 1 == 2\n"
)


@contextlib.contextmanager
def _modules(sources: dict[str, str]) -> Iterator[list[str]]:
    """Write `{name: source}` to a temp dir on `sys.path`; yield the names.

    Cleans the temp dir off `sys.path` and evicts the modules from
    `sys.modules` afterwards so repeated `main` calls re-import freshly.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        for name, src in sources.items():
            (Path(tmpdir) / f"{name}.py").write_text(src)
        sys.path.insert(0, tmpdir)
        try:
            yield list(sources)
        finally:
            sys.path.remove(tmpdir)
            for name in sources:
                sys.modules.pop(name, None)


class TpxPytestBridgeTest(unittest.TestCase):
    def _run(
        self, sources: dict[str, str], extra_argv: list[str] | None = None
    ) -> tuple[int, list[dict]]:
        """Run the bridge over `sources`, returning `(exit_code, json_results)`."""
        with _modules(sources) as test_modules, tempfile.TemporaryDirectory() as outdir:
            out_path = Path(outdir) / "results.json"
            argv = ["--output", str(out_path), *(extra_argv or [])]
            code = tpx_pytest_bridge.main(argv, test_modules)
            results = json.loads(out_path.read_text())
        return code, results

    def _list(
        self, sources: dict[str, str], list_format: str | None = None
    ) -> tuple[int, list[str]]:
        """Run `--list-tests`, returning `(exit_code, printed lines)`.

        Passes `-s` so pytest leaves stdout alone and `_ListPlugin`'s prints
        land in our buffer (tpx reads the real fd instead, so it doesn't
        need this).
        """
        argv = ["--list-tests", "-s"]
        if list_format is not None:
            argv += ["--list-format", list_format]
        with _modules(sources) as test_modules:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = tpx_pytest_bridge.main(argv, test_modules)
        lines = [line for line in buf.getvalue().splitlines() if line]
        return code, lines

    def test_passing_tests_run_and_succeed(self) -> None:
        code, results = self._run({"test_pass": _PASSING})
        self.assertEqual(code, 0)
        # A SUCCESS record proves the test was actually executed, not merely
        # that nothing was collected (which would be exit code 5, nonzero).
        statuses = [r["type"] for r in results]
        self.assertEqual(statuses, ["SUCCESS"])

    def test_failing_tests_cause_nonzero_exit(self) -> None:
        code, results = self._run({"test_fail": _FAILING})
        self.assertNotEqual(code, 0)
        self.assertIn("FAILURE", [r["type"] for r in results])

    def test_collection_failure_is_detected(self) -> None:
        code, results = self._run({"test_broken": _COLLECTION_ERROR})
        self.assertNotEqual(code, 0)
        self.assertIn("FAILURE", [r["type"] for r in results])

    def test_passing_and_failing_mix_fails_overall(self) -> None:
        code, results = self._run({"test_pass": _PASSING, "test_fail": _FAILING})
        self.assertNotEqual(code, 0)
        statuses = [r["type"] for r in results]
        self.assertEqual(statuses.count("SUCCESS"), 1)
        self.assertEqual(statuses.count("FAILURE"), 1)

    def test_non_test_modules_are_filtered_out(self) -> None:
        # `decoy` has a failing test but isn't a test module, so it must not
        # run; the overall result is just the one passing test.
        code, results = self._run({"test_pass": _PASSING, "decoy": _DECOY})
        self.assertEqual(code, 0)
        statuses = [r["type"] for r in results]
        self.assertEqual(statuses, ["SUCCESS"])

    def test_no_test_modules_returns_failure(self) -> None:
        # Every name is filtered out, so the bridge bails before running
        # pytest and reports failure (no JSON is written on this path).
        # 70 mirrors prelude's TEST_FAILURE exit code -- see `_map_exit_code`.
        self.assertEqual(tpx_pytest_bridge.main([], ["decoy", "helpers"]), 70)

    def test_test_suffix_modules_are_discovered(self) -> None:
        # Exercises the `*_test` half of the discovery filter (the other
        # cases all use the `test_*` prefix).
        code, results = self._run({"thing_test": _PASSING})
        self.assertEqual(code, 0)
        self.assertEqual([r["type"] for r in results], ["SUCCESS"])

    def test_regex_selects_a_subset(self) -> None:
        code, results = self._run(
            {"test_alpha": _PASSING, "test_beta": _PASSING},
            extra_argv=["--regex", "alpha"],
        )
        self.assertEqual(code, 0)
        self.assertEqual([r["testCaseName"] for r in results], ["test_alpha"])

    def test_list_tests_python_format(self) -> None:
        code, lines = self._list({"test_list": _PASSING})
        self.assertEqual(code, 0)
        # `_ListPlugin` renders `name (module)` in the default python format.
        self.assertEqual(lines, ["test_passes (test_list)"])

    def test_list_tests_buck_format(self) -> None:
        code, lines = self._list({"test_list": _PASSING}, list_format="buck")
        self.assertEqual(code, 0)
        # Buck format is `module#name`, the id tpx round-trips via `--regex`.
        self.assertEqual(lines, ["test_list#test_passes"])

    def test_skipped_tests_are_assumption_violations(self) -> None:
        # A skip isn't a failure, so the run still succeeds overall.
        code, results = self._run({"test_skip": _SKIPPED})
        self.assertEqual(code, 0)
        self.assertEqual([r["type"] for r in results], ["ASSUMPTION_VIOLATION"])

    def test_class_based_test_naming(self) -> None:
        _, results = self._run({"test_class": _CLASS_BASED})
        self.assertEqual(len(results), 1)
        record = results[0]
        # Class lives in `testCaseName`; the method name in `testCase`.
        self.assertEqual(record["testCaseName"], "test_class.TestThing")
        self.assertEqual(record["testCase"], "test_method")

    def test_failure_record_carries_message_and_captured_stdout(self) -> None:
        _, results = self._run({"test_loud": _FAILING_WITH_OUTPUT})
        self.assertEqual(len(results), 1)
        record = results[0]
        self.assertEqual(record["type"], "FAILURE")
        self.assertTrue(record["message"])
        self.assertTrue(record["stacktrace"])
        self.assertIn("marker-on-stdout", record["stdOut"])


if __name__ == "__main__":
    unittest.main()
