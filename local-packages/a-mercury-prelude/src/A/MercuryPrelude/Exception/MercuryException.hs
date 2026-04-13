-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# LANGUAGE CPP #-}

-- | This module contains the class 'MercuryException' and the type
-- 'SomeMercuryException'. A 'MercuryException' is an 'Exception' that has
-- more built-in power for exception reporting in the various entry points
-- of our application.
module A.MercuryPrelude.Exception.MercuryException
  ( MercuryException (..),
    SomeMercuryException (..),
    ExceptionViaMercuryException (..),
  )
where

import A.MercuryPrelude.Exception.Internal
import Data.Typeable
import Prelude

#ifdef __OSS__
-- FIXME(jadel): icky hacks.
type BeforeNotify = forall a. a -> a
#else
import Network.Bugsnag.BeforeNotify
#endif

-- | This class has the requirements for what a 'MercuryException' ought to
-- be able to do, in addition to being thrown and caught. We can use this
-- class to enhance all exceptions that are thrown or reported in our
-- system.
--
-- Methods in this class all have reasonable defaults, so you can
-- auto-derive them.
class (Exception e) => MercuryException e where
  -- | When this exception is reported, the bugsnag report should be
  -- modified according to this function.
  exceptionModifyBugsnagReport :: e -> BeforeNotify
  exceptionModifyBugsnagReport _ = id

  -- | When this exception is caught by the top-level exception handler in
  -- a Yesod route, use this status code by default.
  --
  -- TODO: Use this as a Yesod middleware
  exceptionHttpStatusCode :: e -> Int
  exceptionHttpStatusCode _ = 500

-- | A wrapper for 'MercuryException's. This type is equivalent to
-- 'SomeException', but for this.
--
-- In general, you should not use the constructor directly. Use
-- 'toException' on types with 'MercuryException' instances instead.
data SomeMercuryException where
  SomeMercuryException :: MercuryException e => e -> SomeMercuryException

deriving stock instance Show SomeMercuryException

instance Exception SomeMercuryException where
  displayException (SomeMercuryException exn) =
    displayException exn

-- | This is a newtype used for @DerivingVia@ enabled 'Exception'
-- instances. Example use:
--
-- @
-- data MyException = MyException
--   deriving stock Show
--   deriving Exception via (ExceptionViaMercuryException MyException)
--
-- instance MercuryException MyException where
--   exceptionHttpStatusCode _ = 400
-- @
newtype ExceptionViaMercuryException a = ExceptionViaMercuryException a
  deriving stock (Show)

instance (MercuryException a) => Exception (ExceptionViaMercuryException a) where
  fromException a = do
    SomeMercuryException inner <- fromException a
    ExceptionViaMercuryException <$> cast inner
  toException (ExceptionViaMercuryException a) =
    toException (SomeMercuryException a)
  displayException (ExceptionViaMercuryException exn) =
    displayException exn
