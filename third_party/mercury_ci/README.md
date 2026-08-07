<!--
SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.

SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Python CI base

This is the base of a CI toolkit for Mercury CI.
We build things like our Haskell CI jobs on top of it, as well as open source CI, which is why it's open source.

## Usage

Depend on `//third_party/mercury_ci`.

### Modules

- `actions` — `AbstractCiActions`/`CiActions` and the `Buck2` wrapper (`run`,
  `build`, `test`, `uquery`, `-m` modifiers).
- `buck` — `BuckTarget`, a validated `cell//package:name` label parser.
- `git` — `Git` wrapper and `GitStatusEntry`, parsing NUL-framed
  `git status --porcelain=v1 -z` (renames report both source and destination).
- `github` — `write_output`, injection-safe `$GITHUB_OUTPUT` writes.
- `nix` — host-to-Nix-system mapping.
- `runners` — canonical CI runner labels.
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
