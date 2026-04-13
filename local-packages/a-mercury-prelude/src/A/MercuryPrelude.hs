-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | This module is our custom prelude.
--
-- This module must not depend on anything defined inside of the @mwb@ package.
-- We want to keep this module as a Prelude that we can import into *any* module
-- in @mwb@, and that means that nothing in @mwb@ can be imported here.
-- If we imported any module in here that is defined in @mwb@, then we wouldn't
-- be able to enforce that this prelude is the one used in *that* module.
--
-- As a result, this module should only import modules from external packages.
--
-- This module should also *mostly* be re-exporting items from those external
-- modules. However, it is sometimes useful to provide temporary compatibility
-- shims. As an example, consider 'throwIO'. This is a function defined in
-- "Control.Exception" and "UnliftIO.Exception" but not in
-- "Control.Annotated.Exception.UnliftIO", which instead uses the name
-- 'throwWithCallStack'. -- We wanted to be able to use 'throwWithCallStack'
-- from @annotated-exception@, but we also didn't necessarily want to incur a
-- huge diff by rewriting all 'throwIO' as 'throwWithCallStack'. So we can
-- define a temporary compatibility shim in this module.
--
-- The reason why this is called "A.MercuryPrelude" is because we currently use
-- @fourmolu@ to format our codebase, and it is quite opinionated about
-- imports - namely, that they must exist in a single, alphabetized block.
--
-- Unfortunately, GHC also cares about import ordering - if two modules @A@ and
-- @B@ export a shared set of terms, then GHC may report redundant import
-- warnings. The redundant import is determined by which one comes *after*, if
-- and only if it does not introduce any novel imports.
--
-- This means that GHC may warn that a Prelude-ish module is redundant if we
-- don't happen to import anything from it that isn't imported from, say,
-- "Data.Text" or similar that happens to overlap.
--
-- We don't want to have our custom prelude export Text, ByteString, etc, and
-- then see redundant import warnings on the Prelude because @Data@ comes before
-- @MercuryPrelude@ alphabetically.
module A.MercuryPrelude
  ( module A.MercuryPrelude.ClassyPrelude,
    module A.MercuryPrelude.Data.Time,
    module A.MercuryPrelude.Data.Type.Equality,
    module A.MercuryPrelude.Exception,
    module A.MercuryPrelude.GHC.Stack,
    module A.MercuryPrelude.MonadTime,
    module A.MercuryPrelude.RequireCallStack,

    -- * Async and Concurrency utilities
    module A.MercuryPrelude.Concurrent,

    -- * Container types
    module A.MercuryPrelude.Data.List.NonEmpty,

    -- * Foldable and Traversable
    module A.MercuryPrelude.Data.Foldable,
    module A.MercuryPrelude.Data.Traversable,

    -- * Miscellaneous utilities
    module A.MercuryPrelude.Utilities,
  )
where

import A.MercuryPrelude.ClassyPrelude
import A.MercuryPrelude.Concurrent
import A.MercuryPrelude.Data.Foldable
import A.MercuryPrelude.Data.List.NonEmpty
import A.MercuryPrelude.Data.Time
import A.MercuryPrelude.Data.Traversable
import A.MercuryPrelude.Data.Type.Equality
import A.MercuryPrelude.Exception
import A.MercuryPrelude.GHC.Stack
import A.MercuryPrelude.MonadTime
import A.MercuryPrelude.RequireCallStack
import A.MercuryPrelude.Utilities
