# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Mercury-owned semantic convention names used by Mercury CI spans."""

CI_REQUIRED_CHECK = "mercury.ci.is_required_check"
"""Whether the CI job is a required check."""

DEPRECATED_CI_REQUIRED_CHECK = "ci_required_check"
"""Deprecated required-check flag for existing Honeycomb queries."""

CI_RUN_CHILD_COUNT = "mercury.ci.run.child_span_count"
"""Number of child-process spans created during the CI job."""

CI_RUN_EXIT_CODE = "mercury.ci.run.exit_code"
"""Final process exit code represented by the CI job root span."""

CI_RUN_FAILED_CHILD_COUNT = "mercury.ci.run.failed_child_span_count"
"""Number of child-process spans whose commands exited unsuccessfully."""

VCS_REF_HEAD_REVISION = "vcs.ref.head.revision"
"""Head revision being evaluated."""

BTD_BASE_REVISION = "btd.base.revision"
"""Base revision used for comparison."""

BTD_UNIVERSE_PATTERN_COUNT = "btd.universe.pattern.count"
"""Repository patterns in the comparison universe."""

BTD_BASE_GRAPH_TARGET_COUNT = "btd.graph.base.target.count"
"""Targets in the base graph."""

BTD_HEAD_GRAPH_TARGET_COUNT = "btd.graph.head.target.count"
"""Targets in the head graph."""

BTD_AFFECTED_TARGET_COUNT = "btd.affected.target.count"
"""Targets reported affected before exclusions."""

BTD_SELECTED_TARGET_COUNT = "btd.selected.target.count"
"""Affected targets remaining after exclusions."""

BTD_EXCLUDED_TARGET_COUNT = "btd.excluded.target.count"
"""Affected targets removed by exclusions."""

BTD_FAILURE_PHASE = "btd.failure.phase"
"""Planner phase that raised an error."""

BTD_TARGET_COUNT = "btd.target.count"
"""Compatible selected targets per platform."""
