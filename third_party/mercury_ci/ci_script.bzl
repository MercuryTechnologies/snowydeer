# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Defines a ci_script macro which helps cut down the boilerplate in BUCK files
defining CI scripts using //third_party/mercury_ci.
"""

def ci_script(
        name,
        main,
        deps = [],
        args = [],
        env = {}):
    target = "{}//{}:{}".format(
        native.get_cell_name(),
        native.package_name(),
        name,
    )

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
            "MERCURY_CI_TARGET": target,
        } | env,
    )
