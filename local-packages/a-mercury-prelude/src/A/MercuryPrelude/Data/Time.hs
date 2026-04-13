-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# OPTIONS_GHC -fno-warn-orphans #-}

module A.MercuryPrelude.Data.Time
  ( module A.MercuryPrelude.Data.Time,
    module Data.Time.Clock,
  )
where

import Data.Aeson.TypeScript.TH
import Data.Time (DiffTime, UTCTime (..))
import Data.Time.Calendar (Day (..), addDays, addGregorianMonthsClip)
import Data.Time.Clock (NominalDiffTime, addUTCTime, diffUTCTime, nominalDay, nominalDiffTimeToSeconds, secondsToNominalDiffTime)
import Data.Time.Clock.POSIX
import Test.QuickCheck
import Prelude

addDaysUTC :: Integer -> UTCTime -> UTCTime
addDaysUTC days utct = utct {utctDay = addDays days utct.utctDay}

addMonthsUTC :: Integer -> UTCTime -> UTCTime
addMonthsUTC months utct = utct {utctDay = addGregorianMonthsClip months utct.utctDay}

instance TypeScript UTCTime where
  getTypeScriptType _ = "string"

instance TypeScript Day where
  getTypeScriptType _ = "string"

-- Data.Time instances taken from https://hackage.haskell.org/package/quickcheck-instances-0.3.25.2/docs/src/Test.QuickCheck.Instances.Time.html

instance Arbitrary UTCTime where
  arbitrary =
    UTCTime
      <$> arbitrary
      <*> (fromRational . toRational <$> choose (0 :: Double, 86_400))
  shrink ut@(UTCTime day dayTime) =
    [ut {utctDay = d'} | d' <- shrink day]
      ++ [ut {utctDayTime = t'} | t' <- shrink dayTime]

instance Arbitrary Day where
  arbitrary = ModifiedJulianDay . (61_000 +) <$> arbitrary
  shrink = (ModifiedJulianDay <$>) . shrink . toModifiedJulianDay

instance Arbitrary DiffTime where
  arbitrary = arbitrarySizedFractional
  shrink = shrinkRealFrac

instance Arbitrary POSIXTime where
  arbitrary = fromRational . toRational <$> choose (0 :: Double, 86_400)
