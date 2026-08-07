<!--
SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc

SPDX-License-Identifier: MIT OR Apache-2.0
-->

# pypi dependencies for buck2

This is a set of Python dependencies from <https://pypi.org> for usage with buck2.

The way that it works is that `uv` makes a build plan for all the Python packages we care about in `uv.lock`.
Next, [`elk`][elk] generates buck targets for every package in `uv.lock`, using a Starlark macro.

[elk]: https://github.com/cormacrelf/elk

## Usage

Try it out:

```
buck run //third_party/python/demo
```

See what's available:

```
buck targets //third_party/python:
```

Add a package: edit `./pyproject.toml`, then:

```
# buck2 kill is required due to a buck2 core bug: https://github.com/facebook/buck2/pull/1286
uv lock && buck2 kill
```

Depend on a package:

```starlark
python_binary(
    name = "test",
    main = "test.py",
    deps = [
        "//third_party/python:requests",
    ],
)
