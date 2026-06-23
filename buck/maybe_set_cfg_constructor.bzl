# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Conditionally sets up the cfg constructor for modifiers. This is only valid to
do inside the root cell (otherwise it causes eval errors), so we have to
conditionalize it.
"""

shim_is_root_cell = read_root_config("mercury", "is_shim", "false") == "true"

def maybe_set_cfg_constructor(**kwargs):
    if shim_is_root_cell:
        native.set_cfg_constructor(**kwargs)
