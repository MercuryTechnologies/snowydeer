-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | We used to use the variants defined in @mono-traversable@, but the type
-- signatures for these functions would often confuse people. However, we've
-- also grown accustomed to calling 'length' on a 'Text', so clearly some of
-- them are useful. For that reason, we retain some of the @mono-traversable@
-- functions and some from "Data.Foldable" or "Data.Foldable1".
--
-- Note that "Data.Foldable" contains a number of functions which throw when
-- given an empty list, such as 'maximum' - we avoid re-exporting these here,
-- and instead re-export the total versions from "Data.Foldable1".
module A.MercuryPrelude.Data.Foldable
  ( module Data.Foldable,
    module Data.Foldable1,
    foldl,
    foldlLazy,
  )
where

import Data.Foldable hiding
  ( all,
    any,
    concat,
    concatMap,
    elem,
    foldl,
    foldl1,
    foldr1,
    length,
    maximum,
    maximumBy,
    minimum,
    minimumBy,
    msum,
    notElem,
    null,
  )
import Data.Foldable qualified
import Data.Foldable1
  ( foldl1,
    foldl1',
    foldr1,
    foldr1',
    head,
    last,
    maximum,
    maximumBy,
    minimum,
    minimumBy,
  )
import GHC.TypeError (ErrorMessage (..), Unsatisfiable, unsatisfiable)

-- | A trap for 'Data.Foldable.foldl' that produces a compile error with a
-- helpful message directing users to 'foldl'' or 'foldlLazy'.
foldl ::
  Unsatisfiable
    ( 'Text "foldl (unlike its stricter sister foldl') is likely to cause"
        ':$$: 'Text "memory leaks due to its laziness and should not be used."
        ':$$: 'Text ""
        ':$$: 'Text "Use foldl' instead. If you know why you need lazy foldl, use foldlLazy."
    ) =>
  a
foldl = unsatisfiable

-- | Here lies 'Data.Foldable.foldl', who lived a misunderstood life of memory
-- leaks and performance issues.
--
-- If you want to use it, it's here, but please think about why you need it
-- instead of 'foldl'' or 'foldr' before using it.
foldlLazy :: Foldable t => (b -> a -> b) -> b -> t a -> b
foldlLazy = Data.Foldable.foldl
