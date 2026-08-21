# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Validation for Buck2 target-label documentation."""

import re
import typing
from collections.abc import Mapping, Sequence

from mercury_ci.actions import AbstractCiActions, Buck2


def find_undocumented_labels(
    target_attributes: Sequence[Mapping[str, object]], documentation: str
) -> list[str]:
    """Return target labels without a matching level-two Markdown heading."""
    labels = {
        label
        for attributes in target_attributes
        for label in typing.cast(list[str], attributes.get("labels", []))
    }
    headings = {
        heading.strip()
        for heading in re.findall(r"^## `([^`\n]+)`$", documentation, re.MULTILINE)
    }
    return sorted(labels - headings)


def check_buck_labels_documented(
    ci: AbstractCiActions, documentation_path: str
) -> None:
    """Fail when a label in the evaluated target graph is undocumented."""
    target_attributes = typing.cast(
        list[dict[str, object]], Buck2(ci).utargets(["//..."], ["^labels$"])
    )
    with open(documentation_path) as documentation_file:
        undocumented = find_undocumented_labels(
            target_attributes, documentation_file.read()
        )

    if undocumented:
        headings = "\n".join(f"## `{label}`" for label in undocumented)
        raise RuntimeError(
            f"Buck2 target labels must be documented in {documentation_path}:\n"
            f"{headings}"
        )
