-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# OPTIONS_GHC -fno-warn-duplicate-exports #-}

-- GHC warns because `throwWithCallStack` is exported from RequireCallStack and
-- explicitly, for module doc reasons.

-- | A Mercury centralized module for dealing with exceptions.
module A.MercuryPrelude.Exception
  ( module A.MercuryPrelude.Exception.Internal,
    module A.MercuryPrelude.Exception.MercuryException,
  )
where

import A.MercuryPrelude.Exception.Internal
import A.MercuryPrelude.Exception.MercuryException
