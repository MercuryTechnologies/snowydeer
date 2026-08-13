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
  , nixPrefetchDockerExe :: FilePath
  , buildozerExe :: FilePath
  , nixFlake :: Maybe FilePath
  , verbose :: Bool
  , subcommand :: Subcommand
  }
  deriving stock (Show)

data PushOpts = PushOpts
  { registryLocation :: Text
  , extraTags :: [Text]
  }
  deriving stock (Show)

data BuildCommand
  = DoPush PushOpts
  | DoBuild
  | DoSave
  deriving stock (Show)

data BaseImageCommand
  = DoValidateBaseImage FilePath
  | DoUpdateBaseImage
  | DoLockBaseImage
  deriving stock (Show)

data Subcommand
  = Builder FilePath BuildCommand
  | BaseImage FilePath BaseImageCommand
  deriving stock (Show)

parsePush :: Parser PushOpts
parsePush = do
  registryLocation <- strArgument (metavar "REG-LOCATION" <> help "Where to upload the image to. Tags will be provided for you automatically. For example ghcr.io/mercurytechnologies/somerepo/someimage.")
  extraTags <- many (strOption (long "extra-tag" <> help "Extra tag to upload the image with"))
  pure PushOpts {..}

parseValidate :: Parser BaseImageCommand
parseValidate = do
  outPath <- strOption (long "out" <> metavar "FILE" <> help "Path to write the validation marker file on success")
  pure (DoValidateBaseImage outPath)

buildSubcmds :: Parser BuildCommand
buildSubcmds =
  hsubparser $
    command "push" (info (fmap DoPush parsePush) (progDesc "Push an image to a registry"))
      <> command "build" (info (pure DoBuild) (progDesc "Build an image without pushing it"))
      <> command "save" (info (pure DoSave) (progDesc "Spit out the image as a tarball on stdout for podman load, for running locally"))

baseImageSubcmds :: Parser BaseImageCommand
baseImageSubcmds =
  hsubparser $
    command "validate" (info parseValidate (progDesc "Pull-validate the pinned base image"))
      <> command "update" (info (pure DoUpdateBaseImage) (progDesc "Re-pin the base image to its follows_tag via nix-prefetch-docker"))
      <> command "lock" (info (pure DoLockBaseImage) (progDesc "Re-derive nar hashes for all arches using the existing pinned digest"))

subcmds :: Parser Subcommand
subcmds =
  hsubparser $
    command "builder" (info builderParser (progDesc "Build or push a container image from a build plan"))
      <> command "base-image" (info baseImageParser (progDesc "Validate or update a pinned base image"))
  where
    builderParser = do
      buildPlan <- strArgument (metavar "BUILD-PLAN" <> help "Path to a build plan JSON file")
      cmd <- buildSubcmds
      pure (Builder buildPlan cmd)
    baseImageParser = do
      specPath <- strArgument (metavar "IMAGE-SPEC" <> help "Path to a base_image_spec.json file")
      cmd <- baseImageSubcmds
      pure (BaseImage specPath cmd)

options :: ParserInfo Opts
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
      nixPrefetchDockerExe <- strOption (long "nix-prefetch-docker-exe" <> value "nix-prefetch-docker" <> help "Path to nix-prefetch-docker. Defaults to looking in PATH")
      buildozerExe <- strOption (long "buildozer-exe" <> value "buildozer" <> help "Path to buildozer. Defaults to looking in PATH")
      nixFlake <- optional $ strOption (long "nix-flake" <> help "Path to the nix// flake. Defaults to $PWD/nix")
      verbose <- switch (short 'v' <> long "verbose" <> help "Enable verbose logging")
      subcommand <- subcmds
      pure Opts {..}
