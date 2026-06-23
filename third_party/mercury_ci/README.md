<!--
SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.

SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Python CI base

This is the base of a CI toolkit for Mercury CI.
We build things like our Haskell CI jobs on top of it, as well as open source CI, which is why it's open source.

## Usage

Depend on `//third_party/mercury_ci`.

## Development

You may have to add something like the following to your IDE configuration so that imports get resolved in `third_party/`:

```json
{
    "python.analysis.extraPaths": ["third_party"],
}

```
