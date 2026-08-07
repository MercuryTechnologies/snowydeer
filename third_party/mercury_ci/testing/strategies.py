# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Shared Hypothesis strategies for mercury_ci tests."""

from hypothesis import strategies as st

from mercury_ci.actions import BuckOpts, TestFilters
from mercury_ci.buck import BuckTarget

# Printable ASCII excluding whitespace (0x21–0x7E).
_CELL_CHARS = st.characters(
    min_codepoint=0x21, max_codepoint=0x7E, blacklist_characters=":/"
)
_NAME_CHARS = st.characters(
    min_codepoint=0x21, max_codepoint=0x7E, blacklist_characters=":"
)
_PKG_SEGMENT_CHARS = st.characters(
    min_codepoint=0x21, max_codepoint=0x7E, blacklist_characters="/:"
)
# Package segments: non-empty, not the special path tokens "." or "..".
_pkg_segment = st.text(_PKG_SEGMENT_CHARS, min_size=1).filter(
    lambda s: s not in (".", "..")
)


@st.composite
def buck_targets(draw: st.DrawFn) -> BuckTarget:
    """Generate valid, well-formed `BuckTarget` instances."""
    cell = draw(st.one_of(st.none(), st.text(_CELL_CHARS, min_size=1)))
    package = draw(
        st.one_of(st.just(""), st.lists(_pkg_segment, min_size=1).map("/".join))
    )
    name = draw(st.text(_NAME_CHARS, min_size=1))
    return BuckTarget(cell=cell, package=package, name=name)


buck_label = buck_targets().map(str)

# Unconstrained on purpose: a value that looks like a flag, or like the `--`
# separator, is exactly the interesting case for whether a command line puts
# things where it claims to.
_flag_value = st.text()


buck_opts = st.builds(
    BuckOpts,
    argfiles=st.lists(_flag_value),
    configs=st.dictionaries(_flag_value, _flag_value),
    modifiers=st.lists(_flag_value),
    target_platforms=st.one_of(st.none(), _flag_value),
    extra=st.lists(_flag_value),
)

test_filters = st.builds(
    TestFilters,
    include=st.lists(_flag_value),
    exclude=st.lists(_flag_value),
    always_exclude=st.booleans(),
    build_filtered=st.booleans(),
)
