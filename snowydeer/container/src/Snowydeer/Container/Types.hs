-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

module Snowydeer.Container.Types where

import Data.Aeson qualified as A
import RIO
import Snowydeer.Container.Metadata.Types

newtype StorePath = StorePath {unStorePath :: Text}
  deriving stock (Show)
  deriving newtype (A.FromJSON, A.ToJSON, IsString, Ord, Eq)

-- | Site-specific configuration for Snowydeer
data SnowydeerConfig = SnowydeerConfig
  { extraValidators :: [MetadataValidator]
  }

instance Semigroup SnowydeerConfig where
  a <> b =
    SnowydeerConfig
      { extraValidators = a.extraValidators <> b.extraValidators
      }

instance Monoid SnowydeerConfig where
  mempty = SnowydeerConfig {extraValidators = []}
