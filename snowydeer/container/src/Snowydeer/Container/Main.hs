-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | Executable wrapper for Snowydeer.
module Snowydeer.Container.Main where

import A.MercuryPrelude
import Snowydeer.Container.Application qualified as Snowydeer

main :: IO ()
main = Snowydeer.main
