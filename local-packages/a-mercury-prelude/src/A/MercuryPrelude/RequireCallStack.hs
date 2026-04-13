-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | This module defines the way we use the "RequireCallStack" library's
-- 'RequireCallStack' type. This utility allows us to require that
-- a 'HasCallStack' constraint is propagated when a function can throw an
-- exception.
--
-- Introducing this pervasively is a huge change, which would require a massive
-- diff. Instead, we'll introduce it in stages: we'll define a special 'error'
-- and 'throwWithCallStack' that will have this constraint. Then, functions
-- which throw exceptions will use 'provideCallStackWithNote' to discharge the
-- requirement, *or* they will put the 'RequireCallStack' constraint in their
-- signature.
--
-- For an example, consider this code:
--
-- @
-- foo :: Int -> IO ()
-- foo = error "oh no"
-- @
--
-- While the 'error' call will include a 'CallStack', we only know that it's
-- called at @foo@ - not *where* or *how* @foo@ is called. With this module,
-- 'error' will cause a compilation failure, citing that there's a missing
-- constraint. There are two fixes: one is to add 'RequireCallStack' into the
-- function context.
--
-- @
-- foo :: RequireCallStack => Int -> IO ()
-- foo = error "oh no"
-- @
--
-- Alternatively, you can use 'provideCallStack' to discharge the constraint. If
-- you do that, then you will lose stack trace information if calling functions
-- don't provide a 'HasCallStack' constraint.
--
-- @
-- foo :: HasCallStack => Int -> IO ()
-- foo = provideCallStack error "oh no"
-- @
module A.MercuryPrelude.RequireCallStack
  ( -- * Propagating the Constraint
    RequireCallStack,

    -- * Discharging the Constraint
    provideCallStack,

    -- * Throwing errors
    error,
    errorNoCallStack,
    throwWithCallStack,
  )
where

import ClassyPrelude hiding (error)
import Control.Exception.Annotated qualified as Annotated
import Control.Monad.Catch (MonadThrow)
import GHC.Stack (HasCallStack, withFrozenCallStack)
import RequireCallStack
import Prelude qualified

-- | Throw a runtime exception of type 'UserError'.
--
-- This is a variant of 'Prelude.error' which incurs a 'RequireCallStack'
-- constraint. Unlike 'HasCallStack', this constraint isn't automagically solved
-- - you have to put it in manually. This means that the associated callstacks
-- will be much more useful and complete.
error :: RequireCallStack => String -> a
error = Prelude.error

-- | Throw a runtime exception of type 'UserError'. Unlike 'error', this *does
-- not* incur a 'RequireCallStack', which means that you will get truncated
-- callstacks in error reports.
errorNoCallStack :: HasCallStack => String -> a
errorNoCallStack = Prelude.error

-- | Throw a runtime 'Exception' that includes a 'CallStack' in the annotations.
--
-- This is a variant of "Control.Exception.Annotated.UnliftIO"'s
-- 'Annotated.throwWithCallStack' that incurs the 'RequireCallStack' constraint.
throwWithCallStack :: (RequireCallStack, MonadThrow m, Exception e) => e -> m a
throwWithCallStack = withFrozenCallStack Annotated.throwWithCallStack
