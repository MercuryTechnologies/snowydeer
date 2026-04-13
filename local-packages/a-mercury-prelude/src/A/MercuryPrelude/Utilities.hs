-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# LANGUAGE AllowAmbiguousTypes #-}

module A.MercuryPrelude.Utilities
  ( Proxy (..),
    Void,
    orElse,
    guarded,
    traceIO,
    artificiallyConstrain,
  )
where

import Control.Applicative (Alternative (empty), Applicative (pure))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.Bool (Bool, bool)
import Data.Constraint (pattern Dict)
import Data.Function (flip, (.))
import Data.Maybe (Maybe, fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Void (Void)
import Debug.Trace qualified (traceIO)
import Text.Show (Show (show))

-- | Infix function to provide a default value for a 'Maybe'.
-- Usage: @Nothing `orElse` "foo"@
orElse :: Maybe a -> a -> a
orElse = flip fromMaybe

-- | Lift a value into an 'Alternative' based on a predicate
--
-- @@@
--   guarded (const True) xyz = Just xyz
--   guarded (const False) xyz = Nothing
-- @@@
guarded :: Alternative f => (a -> Bool) -> a -> f a
guarded p x = bool empty (pure x) (p x)

traceIO :: (MonadIO m, Show a) => a -> m ()
traceIO = liftIO . Debug.Trace.traceIO . show

-- | Artifically add an additional constraint to a value that may or may not
-- currently require it.
--
-- This is a tool for breaking down refactors that add or remove a constraint
-- into smaller PRs without tripping the redundant-constraint compiler warning.
artificiallyConstrain :: forall c a. c => a -> a
artificiallyConstrain a = a where _ = Dict @c
