# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Macro that wraps `python_test` so tests run via pytest.

Wires up the pytest bridge in `//third_party/python/pytest:lib` so test
sources can be plain `def test_...(): assert ...` functions with fixtures,
parametrize, and the rest of pytest's feature set. Unittest `TestCase`
classes still work -- pytest discovers them natively.

Usage:

    load("//third_party/python/pytest:pytest.bzl", "pytest")

    pytest(
        name = "test_foo",
        srcs = ["test_foo.py"],
        deps = [":foo_lib"],
    )
"""

def pytest(name, deps = [], **kwargs):
    """Define a `python_test` target that runs via pytest.

    Sets `main_module` to the pytest bridge and appends
    `//third_party/python/pytest:lib` (which pulls in pytest itself) to
    `deps`. All other args are forwarded verbatim to `python_test`.

    `srcs` should match pytest's default discovery -- files named
    `test_*.py` or `*_test.py`. Other srcs are warned about on stderr
    and skipped at runtime.

    Tests are handed to pytest via `--pyargs`, so each test file must be
    importable from the test PAR (i.e. live under a Python package on the
    PAR's `sys.path`). A test-named src that isn't importable is a hard
    error before pytest sees it -- pytest's `--pyargs` would otherwise
    drop it without surfacing the cause, and tpx/buck2 don't reliably
    surface stderr from a passing run, so a silent drop would let
    coverage disappear without a trace.

    Because `--pyargs` is set, positional passthrough args to
    `buck2 run :test -- ...` are interpreted as dotted module names, not
    file paths. `buck2 run :test -- path/to/extra_test.py` will fail with
    `ModuleNotFoundError`. Use flag-style passthrough (`-k pattern`,
    `-m mark`, `-x`, etc.) instead; the modules under test come from
    `srcs`, not the command line.
    """
    if "main_module" in kwargs:
        fail("`main_module` is reserved by the pytest() macro")
    native.python_test(
        name = name,
        main_module = "third_party.python.pytest.tpx_pytest_bridge",
        deps = deps + ["//third_party/python/pytest:lib"],
        **kwargs
    )
