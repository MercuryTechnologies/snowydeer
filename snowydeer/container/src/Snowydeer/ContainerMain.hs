-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | Executable wrapper for Snowydeer.
module Snowydeer.ContainerMain where

import A.MercuryPrelude
import Snowydeer.Container qualified as Snowydeer

main :: IO ()
main = Snowydeer.main
