-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# LANGUAGE ApplicativeDo #-}

-- | CLI options for Snowydeer
module Snowydeer.Container.Opts where

import Options.Applicative
import RIO hiding (error)

data Opts = Opts
  { skopeoExe :: FilePath
  , buildPlan :: Text
  , verbose :: Bool
  , task :: Task
  }
  deriving stock (Show)

data PushOpts = PushOpts
  { registryLocation :: Text
  , extraTags :: [Text]
  }
  deriving stock (Show)

data Task = DoPush PushOpts | DoBuild | DoSave
  deriving stock (Show)

parsePush :: Parser PushOpts
parsePush = do
  registryLocation <- strArgument (metavar "REG-LOCATION" <> help "Where to upload the image to. Tags will be provided for you automatically. For example ghcr.io/mercurytechnologies/somerepo/someimage.")
  extraTags <- many (strOption (long "extra-tag" <> help "Extra tag to upload the image with"))
  pure PushOpts {..}

subcmds :: Parser Task
subcmds =
  hsubparser $
    command "push" (info (fmap DoPush parsePush) (progDesc "Push an image to a registry"))
      <> command "build" (info (pure DoBuild) (progDesc "Build an image without pushing it"))
      <> command "save" (info (pure DoSave) (progDesc "Spit out the image as a tarball on stdout for podman load, for running locally"))

options :: ParserInfo (Opts)
options =
  info
    (parser <**> helper)
    ( fullDesc
        <> progDesc "Build and upload a Docker image from buck2"
        <> header "Snowydeer Container"
    )
  where
    parser = do
      skopeoExe <- strOption (long "skopeo-exe" <> value "skopeo" <> help "Path to a skopeo executable. Defaults to looking in PATH")
      buildPlan <- strArgument (metavar "BUILD-PLAN" <> help "Path to a build plan for the container")
      verbose <- switch (short 'v' <> long "verbose" <> help "Where to upload the image to")
      task <- subcmds
      pure Opts {..}
