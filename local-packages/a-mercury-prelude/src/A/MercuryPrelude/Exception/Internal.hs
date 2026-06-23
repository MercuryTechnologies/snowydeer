-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# OPTIONS_GHC -Wno-duplicate-exports #-}

-- GHC warns because `throwWithCallStack` is exported from RequireCallStack and
-- explicitly, for module doc reasons.

-- | A Mercury centralized module for dealing with exceptions.
module A.MercuryPrelude.Exception.Internal
  ( -- * "A.MercuryPrelude.RequireCallStack"
    module A.MercuryPrelude.RequireCallStack,

    -- * Throwing Exceptions
    MonadIO (..),
    throwWithCallStack,
    throwWithCallStackIO,
    unsafeThrowWithoutAnnotations,
    unsafeThrowImpurely,
    MonadThrow,
    throwWithCallStackM,
    throwString,
    unsafeThrowWithoutAnnotationsIO,
    unsafeThrowWithoutAnnotationsNoModifications,
    unsafeControlExceptionThrow,
    unsafeCatchesWithoutAnnotations,
    fromEither,
    fromEitherM,
    exceptionWithCallStack,
    addCallStackToException,

    -- * Annotations on Exceptions

    -- ** Annotating exceptions
    checkpoint,
    checkpointMany,
    checkpointCallStack,

    -- ** Annotation datatype
    Annotation (..),

    -- ** Querying annotations
    annotatedExceptionCallStack,

    -- * Catching exceptions
    MonadUnliftIO,
    MonadCatch,
    catch,
    handle,
    try,
    tryAnnotated,
    unsafeTryAsync,
    unsafeTryDiscardAnnotations,
    Safe.onException,
    Safe.withException,
    Safe.catchAsync,

    -- ** Catching multiple exception types simultaneously
    catches,
    type ExceptionHandler,
    pattern ExceptionHandler,
    mkExceptionHandler,

    -- * Bracket Pattern and Masking
    MonadMask,
    Safe.bracket,
    Safe.bracket_,
    Safe.bracketOnError,
    Safe.bracketWithError,
    Safe.finally,
    generalBracket,
    generalBracketIO,
    Catch.ExitCase (..),
    Safe.mask,
    Safe.mask_,
    Safe.uninterruptibleMask,
    Safe.uninterruptibleMask_,

    -- * Exception Types
    Exception (..),

    -- ** For deriving "Control.Monad.Catch" classes
    ExceptionViaIO (..),

    -- ** From "Control.Exception"
    SomeException (..),
    ErrorCall (..),
    AsyncException (..),
    BlockedIndefinitelyOnMVar (..),

    -- ** From "Control.Exception.Annotated"
    AnnotatedException (..),
    discardExceptionAnnotations,
  )
where

import A.MercuryPrelude.RequireCallStack
import Control.Exception
  ( AsyncException (..),
    BlockedIndefinitelyOnMVar (..),
    ErrorCall (..),
  )
import Control.Exception qualified
import Control.Exception.Annotated hiding
  ( Handler,
    check,
    throw,
    throwWithCallStack,
    try,
  )
import Control.Exception.Annotated qualified as AnnotatedM
import Control.Exception.Annotated qualified as UE
import Control.Exception.Annotated.UnliftIO qualified as AnnotatedIO
import Control.Exception.Safe qualified as Safe
import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow, generalBracket)
import Control.Monad.Catch qualified as Catch
import Control.Monad.IO.Class
import GHC.Stack (HasCallStack, callStack, withFrozenCallStack)
import System.IO.Unsafe (unsafePerformIO)
import UnliftIO (MonadUnliftIO)
import UnliftIO.Exception qualified as UnliftIO
import Prelude

-- | An alias for 'UE.Handler' which won't conflict with the 'App.Handler' type.
--
-- To construct these, see 'mkExceptionHandler' and 'ExceptionHandler' pattern
-- synonym.
type ExceptionHandler = UE.Handler

-- | This function serves as a wrapper for the 'UE.Handler' type, which has
-- a name conflict with the much more common type 'App.Handler' defined in
-- "App".
mkExceptionHandler :: Exception e => (e -> m a) -> ExceptionHandler m a
mkExceptionHandler e = UE.Handler e

pattern ExceptionHandler :: () => Exception e => (e -> m a) -> ExceptionHandler m a
pattern ExceptionHandler k = UE.Handler k

-- | A variant of 'throwWithCallStack' that uses 'MonadThrow' instead of
-- 'MonadIO'.
throwWithCallStackM ::
  (RequireCallStack, MonadThrow m, Exception e) =>
  e ->
  m a
throwWithCallStackM = withFrozenCallStack AnnotatedM.throwWithCallStack

-- | A variant of 'throwWithCallStackIO' that uses 'MonadIO' instead of
-- 'MonadThrow'.
throwWithCallStackIO ::
  (RequireCallStack, MonadIO m, Exception e) =>
  e ->
  m a
throwWithCallStackIO = liftIO . withFrozenCallStack UE.throwWithCallStack

-- | Synchronously throw the given exception.
unsafeThrowWithoutAnnotations :: HasCallStack => (MonadThrow m, Exception e) => e -> m a
unsafeThrowWithoutAnnotations = Safe.throw

-- | An implementation of 'generalBracket' that uses 'MonadUnliftIO'. Only use
-- this when defining instances - otherwise, prefer 'generalBracket'.
--
-- On the failure path, this rethrows the original exception unchanged. It
-- does not wrap the exception in 'AnnotatedException' or attach a 'CallStack'
-- annotation at the bracket boundary. Annotation responsibility belongs at
-- throw sites (via 'throwWithCallStack' and friends) and at explicit boundary
-- handlers (e.g. @clientRethrow@). Keeping bracket primitives transparent to
-- exception payloads ensures that consumers which expect a bare exception
-- (notably hspec's failure formatter pattern-matching on 'HUnitFailure') are
-- not broken simply because the throw happened inside a 'bracket'-using
-- helper such as state save/restore.
generalBracketIO ::
  (MonadUnliftIO m) =>
  m a ->
  (a -> Catch.ExitCase b -> m c) ->
  (a -> m b) ->
  m (b, c)
generalBracketIO acquire release action = do
  UnliftIO.mask \restore -> do
    x <- acquire
    res1 <- UnliftIO.try $ restore $ action x
    case res1 of
      Left e1 -> do
        -- explicitly ignore exceptions from after
        _ :: Either SomeException c <-
          UnliftIO.try $ UnliftIO.uninterruptibleMask_ $ release x (Catch.ExitCaseException e1)
        UnliftIO.throwIO e1
      Right y -> do
        c <- UnliftIO.uninterruptibleMask_ $ release x (Catch.ExitCaseSuccess y)
        pure (y, c)

fromEither :: (Exception e, MonadThrow m, RequireCallStack) => Either e a -> m a
fromEither = either throwWithCallStack pure

fromEitherM :: (Exception e, MonadThrow m, RequireCallStack) => m (Either e a) -> m a
fromEitherM = (>>= fromEither)

-- | An alias for 'tryAnnotated'. Prefer to use 'catch' instead, which
-- handles the annotations intelligently for you.
try :: forall e m a. (MonadCatch m, Exception e) => m a -> m (Either (AnnotatedException e) a)
try = tryAnnotated

-- | This function attempts to catch an exception of type @e@. If the
-- underlying code throws an @'AnnotatedException' e@, then you will lose
-- all the exception information, including callstacks. Please only use
-- this if you are absolutely certain that you do not want it.
unsafeTryDiscardAnnotations ::
  forall e m a.
  (MonadCatch m, Exception e) =>
  m a ->
  m (Either e a)
unsafeTryDiscardAnnotations = AnnotatedM.try

-- | This function discards all the exceptions from an
-- 'AnnotatedException'. If you call this, you are probably destroying
-- valuable information. Please try to find some way to propagate the
-- useful information.
discardExceptionAnnotations :: AnnotatedException e -> e
discardExceptionAnnotations (AnnotatedException _ e) = e

-- |
--
-- TODO: upstream to @annotated-exception@
handle :: (Exception e, HasCallStack, MonadCatch m) => (e -> m a) -> m a -> m a
handle handler action =
  withFrozenCallStack catch action handler

-- | A @deriving via@ wrapper that derives instances of 'MonadThrow',
-- 'MonadCatch', and 'MonadMask' through an underlying 'MonadIO' or
-- 'MonadUnliftIO' constraint. Additionally, it uses 'throwWithCallStack' for
-- throwing.
newtype ExceptionViaIO m a = ExceptionViaIO (m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO)

instance MonadIO m => MonadThrow (ExceptionViaIO m) where
  throwM = provideCallStack throwWithCallStackIO

instance MonadUnliftIO m => MonadCatch (ExceptionViaIO m) where
  catch = AnnotatedIO.catch

instance MonadUnliftIO m => MonadMask (ExceptionViaIO m) where
  generalBracket = generalBracketIO
  mask = UnliftIO.mask
  uninterruptibleMask = UnliftIO.uninterruptibleMask

-- | An alias for 'UnliftIO.throwIO'. This should only be used in truly extremely
-- exceptional circumstances - when you're trying to test exception
-- behavior, or rethrow things in very careful and specific ways.
unsafeThrowWithoutAnnotationsIO ::
  (MonadIO m, Exception e) =>
  e ->
  m a
unsafeThrowWithoutAnnotationsIO = UnliftIO.throwIO

-- | This function throws an exception without a monad. You should only do this
-- if you are extremely sure about what you're doing.
unsafeThrowImpurely :: (RequireCallStack, Exception e) => e -> a
unsafeThrowImpurely = unsafePerformIO . withFrozenCallStack throwWithCallStack

-- | An alias for "Control.Exception"'s 'Control.Exception.throwIO'. This
-- function should only be used if you intentionally want to avoid all of the
-- safety and observability benefits of the @safe-exceptions@ package and
-- @annotated-exception@.
unsafeThrowWithoutAnnotationsNoModifications ::
  (Exception e) =>
  e ->
  IO a
unsafeThrowWithoutAnnotationsNoModifications =
  Control.Exception.throwIO

-- | An alias for "Control.Exception"'s 'Control.Exception.throw'. This
-- function should only be used if you intentionally want to avoid all of the
-- safety and observability benefits of the @safe-exceptions@ package and
-- @annotated-exception@.
unsafeControlExceptionThrow ::
  (Exception e) =>
  e ->
  a
unsafeControlExceptionThrow =
  Control.Exception.throw

-- | An alias for "Control.Exception"'s 'Control.Exception.try'. This function
-- will catch asynchronous exceptions, which makes it extremely dangerous to
-- use. Please only use this if you understand how it can introduce deadlock and processing problems.
unsafeTryAsync :: forall e m a. (MonadCatch m, Exception e) => m a -> m (Either e a)
unsafeTryAsync = Catch.try

-- | An alias for 'UnliftIO.catches'. This should only be used in truly extremely exceptional circumstances -
-- when you're trying to test exception behavior, or catch things in very careful and specific ways.
unsafeCatchesWithoutAnnotations :: MonadUnliftIO m => m a -> [ExceptionHandler m a] -> m a
unsafeCatchesWithoutAnnotations = UnliftIO.catches

-- | A vendored variant of "Control.Exception.Safe" 'Safe.throwString'
throwString :: (MonadThrow m, HasCallStack) => String -> m a
throwString s = provideCallStack throwWithCallStack $ Safe.StringException s callStack
