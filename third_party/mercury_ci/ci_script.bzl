# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Defines a ci_script macro which helps cut down the boilerplate in BUCK files
defining CI scripts using //third_party/mercury_ci.
"""

load("//third_party/mercury_ci:is_full_mercury_repo.bzl", "is_full_mercury_repo")

def ci_script(
        name,
        main,
        deps = [],
        args = [],
        env = {}):
    # Using hotel in OSS doesn't work because the CI script is in the critical
    # path to having hotel, so there's a dependency cycle.
    use_hotel = is_full_mercury_repo

    native.python_binary(
        name = name + ".binary",
        main = main,
        deps = deps,
        typing = True,
    )

    native.command_alias(
        name = name,
        exe = ":" + name + ".binary",
        args = args,
        env = {
            "HOTEL": "$(exe toolchains//:hotel-california)" if use_hotel else "skip",
        } | env,
    )
