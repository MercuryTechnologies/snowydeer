# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Lets you find out if you're running in the full mercury-web-backend repo or in
OSS.

FIXME(jadel): reorg this when we have a good place for language-independent
buck rule support.
"""

is_full_mercury_repo = read_root_config("mercury", "is_full_mercury_repo", "false") == "true"
