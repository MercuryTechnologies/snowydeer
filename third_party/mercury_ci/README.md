<!--
SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.

SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Python CI base

This is the base of a CI toolkit for Mercury CI.
We build things like our Haskell CI jobs on top of it, as well as open source CI, which is why it's open source.

## Usage

Depend on `//third_party/mercury_ci`.

Get an actions object through the context manager:

```python
from mercury_ci.actions import ci_actions
from mercury_ci.telemetry.semconv import CI_REQUIRED_CHECK

with ci_actions() as ci:
    ci.set_root_span_attr(CI_REQUIRED_CHECK, True)
    ci.run_subprocess(["build-tool", "build", "//..."])
```

`ci_actions(*, exit_on_child_failure=True, tracer_provider=None)` is the central piece of the telemetry for `mercury_ci`: it manages the lifetime of your workflow's root span.
Facilities provided by the `CiActions` system provide automatic instrumentation for your workflows.

By using this, you automatically get:
- root span, with your `ci_script` target's name
- propagation of otel context to child processes
- tracing of child processes (including args! please don't put secrets in subprocess args)

There are testing facilities for writing tests for the telemetry your code emits in `mercury_ci.testing.telemetry`.

### Modules

- `actions` — `AbstractCiActions`/`CiActions` and the `Buck2` wrapper (`run`,
  `build`, `test`, `uquery`, `-m` modifiers).
- `buck` — `BuckTarget`, a validated `cell//package:name` label parser.
- `git` — `Git` wrapper and `GitStatusEntry`, parsing NUL-framed
  `git status --porcelain=v1 -z` (renames report both source and destination).
- `github` — `write_output`, injection-safe `$GITHUB_OUTPUT` writes.
- `nix` — host-to-Nix-system mapping.
- `runners` — canonical CI runner labels.
- `telemetry` — OpenTelemetry provider setup, context propagation, and spans.
- `testing` — `RecordingCiActions`, a non-executing fake for unit tests.

## Testing

```
buck2 test //third_party/mercury_ci/tests:tests
```

## Development

You may have to add something like the following to your IDE configuration so that imports get resolved in `third_party/`:

```json
{
    "python.analysis.extraPaths": ["third_party"],
}

```
