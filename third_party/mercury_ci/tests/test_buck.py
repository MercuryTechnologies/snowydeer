# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Tests for `mercury_ci.buck.BuckTarget`."""

import pytest
from hypothesis import given

from mercury_ci.buck import BuckPackagePattern, BuckTarget
from mercury_ci.testing.strategies import buck_targets


def test_cell_relative() -> None:
    target = BuckTarget.parse("nix//bin:bwat")
    assert (target.cell, target.package, target.name) == ("nix", "bin", "bwat")
    assert str(target) == "nix//bin:bwat"


def test_no_cell() -> None:
    target = BuckTarget.parse("//bin:bwat")
    assert target.cell is None
    assert str(target) == "//bin:bwat"


def test_nested_package() -> None:
    target = BuckTarget.parse("root//tools/build/platforms:linux-x86_64")
    assert target.package == "tools/build/platforms"
    assert target.name == "linux-x86_64"


@pytest.mark.parametrize(
    ("configured", "expected"),
    [
        ("root//tools/a:test", "root//tools/a:test"),
        (
            "root//tools/a:test (root//platforms:default#123)",
            "root//tools/a:test",
        ),
        (
            "toolchains//:cxx (cfg:<empty>#abc) (root//platforms:default#123)",
            "toolchains//:cxx",
        ),
    ],
)
def test_parse_configured_discards_configuration(
    configured: str, expected: str
) -> None:
    assert str(BuckTarget.parse_configured(configured)) == expected


@pytest.mark.parametrize(
    ("raw", "matching", "not_matching"),
    [
        ("root//:", "root//:mwb", "root//src:mwb"),
        ("root//src/...", "root//src/Foo:test", "root//source:test"),
        ("toolchains//...", "toolchains//:btd", "root//toolchains:btd"),
    ],
)
def test_package_pattern_matches_targets(
    raw: str, matching: str, not_matching: str
) -> None:
    pattern = BuckPackagePattern.parse(raw)
    assert str(pattern) == raw
    assert pattern.matches(BuckTarget.parse(matching))
    assert not pattern.matches(BuckTarget.parse(not_matching))


@pytest.mark.parametrize(
    "raw",
    ["//src/...", "root//src", "root//src:*", "root//src/.../nested"],
)
def test_package_pattern_rejects_unsupported_syntax(raw: str) -> None:
    with pytest.raises(ValueError):
        BuckPackagePattern.parse(raw)


@pytest.mark.parametrize("label", ["//:mwb_ghci", "root//:foo"])
def test_root_package(label: str) -> None:
    target = BuckTarget.parse(label)
    assert target.package == ""
    assert str(target) == label


@pytest.mark.parametrize(
    "name",
    [
        # Structural parser only: broad, consumer-safe punctuation is preserved,
        # including real repo third-party crate names with `+` and `.`.
        "hello.world-1_2",
        "a+b",
        "serde_yaml-0.9.34+deprecated.crate",
        "toml-1.1.2+spec-1.1.0.crate",
    ],
)
def test_permits_broad_name_punctuation(name: str) -> None:
    target = BuckTarget.parse(f"//pkg:{name}")
    assert target.name == name
    assert BuckTarget.parse(str(target)) == target


@pytest.mark.parametrize(
    "label",
    [
        "bin:bwat",  # no //
        "nix//bin",  # no :
        "nix//bin:",  # empty name
        "root//:",  # empty name (root package)
        "///a:x",  # absolute package (leading /)
        "nix//a//b:x",  # empty package segment
        "//a/:x",  # trailing slash
        "//a/./b:x",  # dot segment
        "//a/../b:x",  # dotdot segment
        "//a b:x",  # whitespace in package
        "//a:b c",  # whitespace in name
        "//a:b:c",  # colon in name
        "//a:b/c:n",  # colon in package segment
        "a/b//pkg:n",  # slash in cell
        "a:b//pkg:n",  # colon in cell
        "//a:b\x00c",  # NUL in name
        "//a:b\tc",  # control char in name
        "//a:b\nc",  # newline in name
    ],
)
def test_rejects_malformed(label: str) -> None:
    with pytest.raises(ValueError):
        BuckTarget.parse(label)


@pytest.mark.parametrize(
    "args",
    [
        (None, "..", "name"),  # dotdot package
        ("nix", "pkg", ""),  # empty name
        ("", "pkg", "name"),  # empty cell is not None
    ],
)
def test_direct_construction_is_validated(args: tuple[str | None, str, str]) -> None:
    with pytest.raises(ValueError):
        BuckTarget(*args)


@given(buck_targets())
def test_round_trip(target: BuckTarget) -> None:
    assert BuckTarget.parse(str(target)) == target
