-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# LANGUAGE CPP #-}

-- | This module introduces 'MonadTime', which we use to remove 'MonadIO'
-- constraints on several functions to make those functions compatible with
-- restricted monads for e.g. database transactions or similar semi-pure
-- contexts.
module A.MercuryPrelude.MonadTime where

import Control.Applicative
import Control.Monad
import Control.Monad.Except (ExceptT (..))
import Control.Monad.IO.Class
import Control.Monad.Logger (LoggingT)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT (..))
import Control.Monad.Trans.Reader (ReaderT (..))
import Control.Monad.Trans.Resource (ResourceT)
import Control.Monad.Trans.State.Lazy (StateT (..))
import Data.Function
import Data.Time hiding (getCurrentTime)
import Data.Time qualified
import System.Clock (Clock (..), TimeSpec (..))
import System.Clock qualified as Clock
import System.IO
import Test.Hspec.Yesod (YesodExample)
#ifndef __OSS__
import Temporal.Workflow (Workflow, now, time)
import RequireCallStack (provideCallStack)
import Data.Time.Clock.System (SystemTime (..))
import Prelude (fromIntegral)
#endif

-- | Class representing monads with access to the current time.
-- Use this class instead of 'MonadIO' if all you need is the current time.
-- This is useful to remove `MonadIO m` constraints from functions in order to make
-- them compatible with `Mercury.Database.Monad` without needing to use `unsafeLiftIODB`.
class Monad m => MonadTime m where
  getCurrentTime :: m UTCTime

  getTime :: Clock -> m TimeSpec

instance MonadTime IO where
  getCurrentTime = Data.Time.getCurrentTime
  {-# INLINE getCurrentTime #-}

  getTime = Clock.getTime
  {-# INLINE getTime #-}

newtype ViaIO m a = ViaIO (m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO)

instance MonadIO m => MonadTime (ViaIO m) where
  getCurrentTime = ViaIO $ liftIO getCurrentTime
  {-# INLINE getCurrentTime #-}

  getTime = ViaIO . liftIO . Clock.getTime
  {-# INLINE getTime #-}

instance (MonadTime m) => MonadTime (MaybeT m) where
  getCurrentTime = lift getCurrentTime
  {-# INLINE getCurrentTime #-}

  getTime = lift . getTime
  {-# INLINE getTime #-}

instance (MonadTime m) => MonadTime (ReaderT r m) where
  getCurrentTime = lift getCurrentTime
  {-# INLINE getCurrentTime #-}

  getTime = lift . getTime
  {-# INLINE getTime #-}

instance (MonadTime m) => MonadTime (ExceptT e m) where
  getCurrentTime = lift getCurrentTime
  {-# INLINE getCurrentTime #-}

  getTime = lift . getTime
  {-# INLINE getTime #-}

instance (MonadTime m) => MonadTime (ResourceT m) where
  getCurrentTime = lift getCurrentTime
  {-# INLINE getCurrentTime #-}

  getTime = lift . getTime
  {-# INLINE getTime #-}

instance MonadTime m => MonadTime (StateT s m) where
  getCurrentTime = lift getCurrentTime
  getTime = lift . getTime

instance MonadTime m => MonadTime (LoggingT m) where
  getCurrentTime = lift getCurrentTime
  {-# INLINE getCurrentTime #-}

  getTime = lift . getTime
  {-# INLINE getTime #-}

#ifndef __OSS__
instance MonadTime Workflow where
  getCurrentTime = now
  {-# INLINE getCurrentTime #-}

  getTime _ = do
    -- The use of 'provideCallStack' here might look a little strange, but the Workflow
    -- monad stores the latest call stack for certain functions so that it can respond
    -- to the "live callstack" query from the Temporal UI.
    MkSystemTime {..} <- provideCallStack time
    pure $ TimeSpec systemSeconds (fromIntegral systemNanoseconds)
  {-# INLINE getTime #-}
#endif

deriving via ViaIO (YesodExample site) instance MonadTime (YesodExample site)
