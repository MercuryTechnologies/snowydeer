-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | A module for operations that "cascade", which is to say, that can
-- be tried in one way and, if that fails, fall back to trying another
-- way.
--
-- A good example of this is geocoding. Perhaps we can use OpenStreetMap more
-- cheaply than Google Maps, so we try OpenStreetMap first, then Google Maps if
-- the geocoding fails. We want to try with each partner, handling failures by
-- trying the next, and so on until one reports success.
--
-- The intention is that this module can be extracted as a standalone
-- library at some point, so try not to import other Mercury-specific
-- stuff in this module.
module A.MercuryPrelude.Cascade
  ( dispatchUntilSucceeded,
    CascadeIteration (..),
    CascadeFailure (..),
    mapContinueF,
    mapStopF,
    continueCascade,
    stopCascade,
    CascadeIterationT (..),
    continueCascadeT,
    stopCascadeT,
    continueLeftT,
    continueLeftM,
    continueLeftWithM,
    withContinueT,
    withStopT,
    CascadeComplete (..),
    CascadeResult (..),
  )
where

import Control.Applicative (Applicative (..))
import Control.Monad (Monad)
import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.Extra (foldM)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans.Class (MonadTrans (..))
import Control.Monad.Trans.Except (ExceptT (ExceptT), withExceptT)
import Data.Either (Either (..))
import Data.Either.Extra (mapLeft)
import Data.Foldable (Foldable)
import Data.Functor (Functor (..))
import Data.List ((++))
import Prelude (Eq, Show, ($), (.))

data CascadeComplete e a
  = CascadeCompleteAllContinued
  | CascadeCompleteStopped e
  | CascadeCompleteSucceeded a
  deriving stock (Eq, Show)

data CascadeResult e c a = CascadeResult
  { cascadeResultFinal :: CascadeComplete e a
  , cascadeResultContinued :: [c]
  }
  deriving stock (Eq, Show)

appendContinue :: c -> CascadeResult e c a -> CascadeResult e c a
appendContinue c result = CascadeResult {cascadeResultContinued = result.cascadeResultContinued ++ [c], cascadeResultFinal = result.cascadeResultFinal}

setSucceeded :: a -> CascadeResult e c a -> CascadeResult e c a
setSucceeded a result = CascadeResult {cascadeResultContinued = result.cascadeResultContinued, cascadeResultFinal = CascadeCompleteSucceeded a}

setStopped :: e -> CascadeResult e c a -> CascadeResult e c a
setStopped e result = CascadeResult {cascadeResultContinued = result.cascadeResultContinued, cascadeResultFinal = CascadeCompleteStopped e}

-- | A type for a failure result during a cascade.
-- In a cascade, a failure of one operation can either mean
-- that we should try another operation ('Continue') or just give
-- up because we can't unwind something we've already done ('Stop').
data CascadeFailure e c
  = Stop e
  | Continue c
  deriving stock (Show, Eq, Functor)

mapContinueF :: (c1 -> c2) -> CascadeFailure e c1 -> CascadeFailure e c2
mapContinueF = fmap

mapStopF :: (e1 -> e2) -> CascadeFailure e1 c -> CascadeFailure e2 c
mapStopF f = \case
  Stop e ->
    Stop (f e)
  Continue c ->
    Continue c

newtype CascadeIteration e c a = CascadeIteration {getCascadeIteration :: Either (CascadeFailure e c) a}
  deriving stock (Show, Eq, Functor)
  deriving (Applicative, Monad) via (Either (CascadeFailure e c))

continueCascade :: c -> CascadeIteration e c a
continueCascade = CascadeIteration . Left . Continue

stopCascade :: e -> CascadeIteration e c a
stopCascade = CascadeIteration . Left . Stop

newtype CascadeIterationT e c m a = CascadeIterationT {runCascadeIterationT :: ExceptT (CascadeFailure e c) m a}
  deriving stock (Functor)
  deriving (Applicative, Monad) via (ExceptT (CascadeFailure e c) m)
  deriving (MonadIO) via (ExceptT (CascadeFailure e c) m)
  deriving (MonadThrow, MonadCatch, MonadMask) via (ExceptT (CascadeFailure e c) m)

-- Generating this with DerivingVia produces a "redundant constraint"
-- error so we just generate it by hand.
-- This might be related to https://gitlab.haskell.org/ghc/ghc/-/issues/23143.
instance MonadTrans (CascadeIterationT e c) where
  lift = CascadeIterationT . lift @(ExceptT (CascadeFailure e c))

continueCascadeT :: Applicative m => c -> CascadeIterationT e c m a
continueCascadeT = CascadeIterationT . ExceptT . pure . Left . Continue

stopCascadeT :: Applicative m => e -> CascadeIterationT e c m a
stopCascadeT = CascadeIterationT . ExceptT . pure . Left . Stop

continueLeftT :: Functor m => ExceptT c m a -> CascadeIterationT e c m a
continueLeftT = CascadeIterationT . withExceptT Continue

-- | Transform the 'Continue' value of a 'CascadeIterationT'.
withContinueT :: Functor m => (c1 -> c2) -> CascadeIterationT e c1 m a -> CascadeIterationT e c2 m a
withContinueT f = CascadeIterationT . withExceptT (mapContinueF f) . runCascadeIterationT

-- | Transform the 'Stop' value of a 'CascadeIterationT'.
withStopT :: Functor m => (e1 -> e2) -> CascadeIterationT e1 c m a -> CascadeIterationT e2 c m a
withStopT f = CascadeIterationT . withExceptT (mapStopF f) . runCascadeIterationT

-- | Convert a functorial 'Either' value into the
-- 'CascadeIterationT' monad, transforming the left value into a
-- Continue value.
continueLeftM :: Functor m => m (Either c a) -> CascadeIterationT e c m a
continueLeftM = CascadeIterationT . ExceptT . fmap (mapLeft Continue)

-- | Convert a functorial 'Either' value into the 'CascadeIterationT'
-- monad, transforming the left value with the given function.
continueLeftWithM :: Applicative m => (c1 -> c2) -> m (Either c1 a) -> CascadeIterationT e c2 m a
continueLeftWithM f = withContinueT f . continueLeftM

dispatchUntilSucceeded :: (Foldable f, Monad m) => (a -> m (CascadeIteration e c b)) -> f a -> m (CascadeResult e c b)
dispatchUntilSucceeded f xs =
  foldM next CascadeResult {cascadeResultContinued = [], cascadeResultFinal = CascadeCompleteAllContinued} xs
  where
    next curr x = do
      case curr.cascadeResultFinal of
        -- We were told to stop. Ignore further elements.
        CascadeCompleteStopped _ -> pure curr
        CascadeCompleteSucceeded _ -> pure curr
        -- No previous result has been definitive. Try the next one.
        CascadeCompleteAllContinued -> do
          res <- f x
          case getCascadeIteration res of
            Left (Continue c) ->
              -- We got a new "continue"; put it at the end of the CascadeResult.
              pure $ appendContinue c curr
            Left (Stop e) ->
              pure $ setStopped e curr
            Right b ->
              pure $ setSucceeded b curr
