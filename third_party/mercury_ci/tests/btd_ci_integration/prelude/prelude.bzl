# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
fake prelude for testing
"""

def _stub(_ctx):
    return [DefaultInfo()]

stub = rule(
    impl = _stub,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
    },
)

def _test(ctx):
    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(
            type = "custom",
            command = ["true" if ctx.attrs.succeeds else "false"],
            labels = ctx.attrs.labels,
        ),
    ]

test = rule(
    impl = _test,
    attrs = {
        "labels": attrs.list(attrs.string(), default = []),
        "succeeds": attrs.bool(default = True),
    },
)

def host_stub(name, os, arch):
    info = host_info()
    os_matches = {
        "linux": info.os.is_linux,
        "macos": info.os.is_macos,
    }
    arch_matches = {
        "aarch64": info.arch.is_aarch64,
        "x86_64": info.arch.is_x86_64,
    }
    if os_matches[os] and arch_matches[arch]:
        stub(name = name)
