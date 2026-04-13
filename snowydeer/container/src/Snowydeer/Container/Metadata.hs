-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | Metadata validation for Snowydeer.
module Snowydeer.Container.Metadata where

import Data.HashMap.Strict qualified as HashMap
import Data.Semigroup (sconcat)
import RIO
import Snowydeer.Container.Metadata.Types

baseRequiredValidators :: [MetadataValidator]
baseRequiredValidators =
  [ MetadataValidator "org.opencontainers.image.description" (const (Right ()))
  ]

validateMetadata :: [MetadataValidator] -> UncheckedMetadata -> Either MetadataError ValidMetadata
validateMetadata extra = runValidators (baseRequiredValidators <> extra)
  where
    runValidators validators metadata =
      let results = map (\v -> oneField v metadata) validators
       in case partitionEithers results of
            (err0 : errs, _) -> Left $ sconcat (err0 :| errs)
            (_, _) -> Right $ ValidMetadata metadata

    oneField :: MetadataValidator -> UncheckedMetadata -> Either MetadataError ()
    oneField MetadataValidator {fieldName, validate} metadata = case HashMap.lookup fieldName metadata of
      Just field ->
        first (\err -> MetadataError ((fieldName, err) :| [])) $
          validate field
      Nothing -> Left $ MetadataError ((fieldName, "Missing required field") :| [])
