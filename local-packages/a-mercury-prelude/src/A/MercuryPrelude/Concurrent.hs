-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | This module defines concurrency functions. It is intended as a drop-in
-- replacement for "Control.Concurrent", "Control.Concurrent.Async", "UnliftIO.Concurrent",
-- "UnliftIO.Async", etc.
--
-- We need this module because our open telemetry functionality uses @thread
-- local context@ to make span information available transparently. However, we
-- need to attach the context on freshly created threads, otherwise the span
-- information in the forked thread won't get reported.
--
-- If you need anything from "UnliftIO.Concurrent" or "Control.Concurrent",
-- please add it to the exports of this module.
module A.MercuryPrelude.Concurrent
  ( -- * "Control.Concurrent.Async" or "UnliftIO.Async" replacements
    Async,
    linkAsync,
    wait,
    async,
    asyncWithUnmask,
    withAsync,
    withAsyncWithUnmask,
    asyncInheritMaskingState,
    concurrently,
    concurrently_,
    forConcurrently,
    forConcurrently_,
    race,
    race_,
    mapConcurrently,
    mapConcurrently_,
    replicateConcurrently,
    replicateConcurrently_,
    rtsSupportsBoundThreads,
    Concurrently (..),
    getNumCapabilities,

    -- ** Pooled versions
    pooledForConcurrently,
    pooledForConcurrentlyN,
    pooledForConcurrentlyN_,
    pooledForConcurrently_,
    pooledMapConcurrently,
    pooledMapConcurrentlyN,
    pooledMapConcurrentlyN_,
    pooledMapConcurrently_,
    pooledReplicateConcurrently,
    pooledReplicateConcurrentlyN,
    pooledReplicateConcurrentlyN_,
    pooledReplicateConcurrently_,

    -- * "Control.Concurrent" replacements
    forkIO,
    forkFinally,
    threadDelay,
    ThreadId,
    myThreadId,
    killThread,
  )
where

import A.MercuryPrelude.Exception (MonadCatch, SomeException, checkpointCallStack)
import ClassyPrelude qualified as ClassyPreludeFull
import Control.Concurrent.Async (Async)
import Control.Monad
import Control.Monad.IO.Class
import GHC.IO qualified
import GHC.Stack (HasCallStack, withFrozenCallStack)
import OpenTelemetry.Context (Context)
import OpenTelemetry.Context.ThreadLocal (attachContext, detachContext, getContext)
import UnliftIO (MonadUnliftIO, bracket, withRunInIO)
import UnliftIO.Async qualified as UnliftIO
import UnliftIO.Concurrent
  ( ThreadId,
    getNumCapabilities,
    killThread,
    myThreadId,
    rtsSupportsBoundThreads,
    threadDelay,
  )
import UnliftIO.Concurrent qualified
import Prelude

-- | An alias for 'UnliftIO.link' that avoids a really common name conflict.
linkAsync :: MonadIO m => Async a -> m ()
linkAsync = UnliftIO.link

unsafeUnmask :: MonadUnliftIO m => m a -> m a
unsafeUnmask action =
  withRunInIO \runInIO ->
    GHC.IO.unsafeUnmask (runInIO action)

-- | Attach the given 'Context' to the thread-local for the duration of
-- @action@; restore the original context upon completion, if any existed.
withAttachedContext :: MonadUnliftIO m => Context -> m a -> m a
withAttachedContext ctx action =
  bracket
    (attachContext ctx)
    (detachContext)
    \_ -> action
{-# INLINE withAttachedContext #-}

concurrently :: (MonadUnliftIO m) => m a -> m b -> m (a, b)
concurrently ma mb = do
  ctx <- getContext
  ClassyPreludeFull.concurrently
    (withAttachedContext ctx ma)
    (withAttachedContext ctx mb)

concurrently_ :: (MonadUnliftIO m) => m a -> m b -> m ()
concurrently_ ma mb = void $ concurrently ma mb

forConcurrently :: (MonadUnliftIO m, Traversable t) => t a -> (a -> m b) -> m (t b)
forConcurrently xs fn =
  getContext >>= \ctx ->
    ClassyPreludeFull.forConcurrently xs (\x -> withAttachedContext ctx $ fn x)

forConcurrently_ :: (MonadUnliftIO m, Traversable t) => t a -> (a -> m b) -> m ()
forConcurrently_ xs = void . forConcurrently xs

-- | Like 'ClassyPreludeFull.race', but the forked threads are 'unsafeUnmask'ed.
-- This is necessary so that the underlying threads can be 'cancel'ed, in the
-- case that 'race' was called inside of a 'bracket' or other masking function.
race :: MonadUnliftIO m => m a -> m b -> m (Either a b)
race ma mb = do
  ctx <- getContext
  ClassyPreludeFull.race
    (withAttachedContext ctx $ unsafeUnmask ma)
    (withAttachedContext ctx $ unsafeUnmask mb)

race_ :: MonadUnliftIO m => m a -> m b -> m ()
race_ ma mb = void $ race ma mb

mapConcurrently :: MonadUnliftIO m => Traversable t => (a -> m b) -> t a -> m (t b)
mapConcurrently fn xs =
  getContext >>= \ctx ->
    ClassyPreludeFull.mapConcurrently (\x -> withAttachedContext ctx $ fn x) xs

pooledMapConcurrently_ :: MonadUnliftIO m => Foldable t => (a -> m b) -> t a -> m ()
pooledMapConcurrently_ fn xs = do
  ctx <- getContext
  UnliftIO.pooledMapConcurrently_ (\x -> withAttachedContext ctx $ fn x) xs

mapConcurrently_ :: MonadUnliftIO m => Traversable t => (a -> m b) -> t a -> m ()
mapConcurrently_ fn = void . mapConcurrently fn

replicateConcurrently :: MonadUnliftIO m => Int -> m b -> m [b]
replicateConcurrently n m =
  getContext >>= \ctx ->
    ClassyPreludeFull.replicateConcurrently n (withAttachedContext ctx m)

replicateConcurrently_ :: (MonadUnliftIO m) => Int -> m a -> m ()
replicateConcurrently_ n action = do
  ctx <- getContext
  UnliftIO.replicateConcurrently_ n $
    withAttachedContext ctx $
      void action

pooledReplicateConcurrently :: (MonadUnliftIO m) => Int -> m b -> m [b]
pooledReplicateConcurrently n action = do
  ctx <- getContext
  UnliftIO.pooledReplicateConcurrently n $
    withAttachedContext ctx action

pooledReplicateConcurrentlyN :: (MonadUnliftIO m) => Int -> Int -> m b -> m [b]
pooledReplicateConcurrentlyN i n action = do
  ctx <- getContext
  UnliftIO.pooledReplicateConcurrentlyN i n $
    withAttachedContext ctx action

pooledReplicateConcurrentlyN_ :: (MonadUnliftIO m) => Int -> Int -> m b -> m ()
pooledReplicateConcurrentlyN_ i n action = do
  ctx <- getContext
  UnliftIO.pooledReplicateConcurrentlyN_ i n $
    withAttachedContext ctx action

pooledReplicateConcurrently_ :: (MonadUnliftIO m) => Int -> m b -> m ()
pooledReplicateConcurrently_ n action = do
  ctx <- getContext
  UnliftIO.pooledReplicateConcurrently_ n do
    withAttachedContext ctx $ void action

pooledMapConcurrently :: (MonadUnliftIO m, Traversable t) => (a -> m b) -> t a -> m (t b)
pooledMapConcurrently a xs = getContext >>= \ctx -> ClassyPreludeFull.pooledMapConcurrently (\x -> withAttachedContext ctx (a x)) xs

pooledMapConcurrentlyN :: (MonadUnliftIO m, Traversable t) => Int -> (a -> m b) -> t a -> m (t b)
pooledMapConcurrentlyN i action xs = do
  ctx <- getContext
  UnliftIO.pooledMapConcurrentlyN i (\x -> withAttachedContext ctx $ action x) xs

pooledMapConcurrentlyN_ :: (MonadUnliftIO m, Traversable t) => Int -> (a -> m b) -> t a -> m ()
pooledMapConcurrentlyN_ i action xs = do
  ctx <- getContext
  UnliftIO.pooledMapConcurrentlyN_ i (\x -> withAttachedContext ctx $ action x) xs

pooledForConcurrently :: (MonadUnliftIO m, Traversable t) => t a -> (a -> m b) -> m (t b)
pooledForConcurrently xs action = do
  ctx <- getContext
  UnliftIO.pooledForConcurrently xs \x -> withAttachedContext ctx $ action x

pooledForConcurrently_ :: (MonadUnliftIO m, Traversable t) => t a -> (a -> m b) -> m ()
pooledForConcurrently_ xs action = do
  ctx <- getContext
  UnliftIO.pooledForConcurrently_ xs \x -> withAttachedContext ctx $ action x

pooledForConcurrentlyN :: (MonadUnliftIO m, Traversable t) => Int -> t a -> (a -> m b) -> m (t b)
pooledForConcurrentlyN i xs action = do
  ctx <- getContext
  UnliftIO.pooledForConcurrentlyN i xs \x -> withAttachedContext ctx $ action x

pooledForConcurrentlyN_ :: (MonadUnliftIO m, Traversable t) => Int -> t a -> (a -> m b) -> m ()
pooledForConcurrentlyN_ i xs action = do
  ctx <- getContext
  UnliftIO.pooledForConcurrentlyN_ i xs \x -> withAttachedContext ctx $ action x

-- | A variant of 'UnliftIO.wait' that annotates the thrown exception with
-- a 'CallStack'.
wait :: (MonadCatch m, MonadIO m, HasCallStack) => Async a -> m a
wait a = withFrozenCallStack checkpointCallStack $ UnliftIO.wait a

-- | Like 'UnliftIO.withAsync', but attaches the current thread
-- context.
--
-- Unlike 'UnliftIO.withAsync', this unmasks asynchronous exceptions in the
-- @create@ thread, which allows the thread to be killed by 'cancel'. Without
-- this, a 'withAsync' called inside of a 'mask' (including called by 'bracket',
-- 'finally', etc) might never terminate.
withAsync :: MonadUnliftIO m => m a -> (Async a -> m r) -> m r
withAsync create =
  withAsyncWithUnmask (\unmask -> unmask create)

-- | Like 'UnliftIO.withAsyncWithUnmask', but attaches the thread context to the
-- forked thread.
withAsyncWithUnmask ::
  MonadUnliftIO m =>
  ((forall x. m x -> m x) -> m a) ->
  (Async a -> m r) ->
  m r
withAsyncWithUnmask create action = do
  cxt <- getContext
  UnliftIO.withAsyncWithUnmask
    (\unmask -> withAttachedContext cxt $ create unmask)
    action

-- | Like 'UnliftIO.async', but attaches the current thread context. Prefer
-- 'withAsync' so that the thread is guaranteed to be cleaned up when the
-- enclosing action terminates.
--
-- Unlike 'UnliftIO.async', the forked action is started in an unmasked state.
-- This means that asynchronous exceptions can kill the thread. This is almost
-- always what you want, as the API for 'Async' requires asynchronous exceptions
-- in order to cancel threads. If you want to create an 'Async' that cannot be
-- killed, and you know enough about asynchronous exceptions to understand why
-- that's a bad idea and why it's OK for you right now, then see
-- 'asyncInheritMaskingState'.
async :: MonadUnliftIO m => m a -> m (Async a)
async create =
  asyncWithUnmask \unmask -> unmask create

-- | Like 'UnliftIO.async', but attaches the current thread context. Prefer
-- 'withAsync' so that the thread is guaranteed to be cleaned up when the
-- enclosing action terminates.
--
-- WARNING: This function inherits the masking state of the parent thread.
-- If the thread is created in a 'bracket' cleanup, 'finally',
-- 'onException', or any other 'uninterruptibleMask', then the resulting
-- 'Async' will be unkillable. This will break the assumptions and
-- expectations of the 'Async' API - you will not be able to 'cancel' the
-- resulting thread.
--
-- If this is created in a 'bracket' initializer or any other 'mask', then
-- the thread will be created in a 'MaskedInterruptible' state. This means
-- that the thread will be killed at the first blocking operation after
-- a 'cancel'. However, you're not guaranteed to run a blocking operation
-- - this exact failure mode caused a production issue, when a tight loop
-- of checking a 'TVar' never allocated or called any blocking functions.
--
-- You almost certainly want 'async' instead.
asyncInheritMaskingState :: MonadUnliftIO m => m a -> m (Async a)
asyncInheritMaskingState create = asyncWithUnmask (const create)

-- | Like 'UnliftIO.asyncWithUnmask', but attaches the current thread
-- context for tracing.
asyncWithUnmask :: MonadUnliftIO m => ((forall x. m x -> m x) -> m a) -> m (Async a)
asyncWithUnmask create = do
  currentThreadContext <- getContext
  UnliftIO.asyncWithUnmask \unmask -> withAttachedContext currentThreadContext $ create unmask

-- | A replacement for "UnliftIO.Concurrent" 'UnliftIO.Concurrent.forkFinally'
-- which preserves the opentelemetry span.
forkFinally ::
  (MonadUnliftIO m) =>
  m a ->
  (Either SomeException a -> m ()) ->
  m ThreadId
forkFinally action handler = do
  currentThreadContext <- getContext
  UnliftIO.Concurrent.forkFinally
    (withAttachedContext currentThreadContext action)
    (\a -> withAttachedContext currentThreadContext $ handler a)

-- | A replacement for "UnliftIO.Concurrent" 'UnliftIO.Concurrent.forkIO' which
-- preserves the open telemetry span.
forkIO :: (MonadUnliftIO m) => m () -> m ThreadId
forkIO action = do
  context <- getContext
  UnliftIO.Concurrent.forkIO $ withAttachedContext context action

-- | A copy of "UnliftIO.Async" 'UnliftIO.Async.Concurrently' which
-- properly preserves the open telemetry context.
newtype Concurrently m a = Concurrently {runConcurrently :: m a}
  deriving newtype (Functor)

instance MonadUnliftIO m => Applicative (Concurrently m) where
  pure =
    Concurrently . pure
  Concurrently fs <*> Concurrently as =
    Concurrently $ fmap (\(f, a) -> f a) (concurrently fs as)
