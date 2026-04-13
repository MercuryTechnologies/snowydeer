-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

module Snowydeer.Container.Metadata.Types where

import Data.Aeson qualified as A
import RIO

type UncheckedMetadata = HashMap Text Text

newtype ValidMetadata = ValidMetadata {unValidMetadata :: UncheckedMetadata}
  deriving stock (Show)
  -- Don't derive FromJSON on this, it needs to actually get checked.
  deriving newtype (A.ToJSON)

-- This is a newtype so it can be an exception.
newtype MetadataError = MetadataError (NonEmpty (Text, Problem))
  deriving stock (Show, Eq)
  deriving anyclass (Exception)
  deriving newtype (Semigroup)

-- | Problem with a field.
newtype Problem = Problem Text
  deriving stock (Show, Eq, Ord)
  deriving newtype (IsString)

data MetadataValidator = MetadataValidator
  { fieldName :: Text
  , validate :: Text -> Either Problem ()
  }
