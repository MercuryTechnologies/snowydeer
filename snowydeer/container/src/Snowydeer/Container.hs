{-# LANGUAGE CPP #-}
-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# LANGUAGE TemplateHaskell #-}

-- | Container builder for Snowydeer.
--
-- This calls Snowydeer on the buck targets that need it, produces the store
-- paths, then passes those into the Nix docker builder.
module Snowydeer.Container
  ( -- * Build plans
    InputPath (..),
    GitRevInfo (..),
    BuildPlan (..),
    buildPlanMetadataL,
    buildPlanContentsL,
    ExportBuildPlan (..),

    -- * Building a plan
    planify,

    -- * App
    AppM,
    App (..),
    Stubs (..),
    asksStub,
    main,
  )
where

import A.MercuryPrelude.ClassyPrelude (ordNub)
import A.MercuryPrelude.RequireCallStack
import Control.Monad qualified as Monad
import Data.Aeson qualified as A
import Data.Aeson.TH qualified as A
import Data.ByteString qualified as BS
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HashSet
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Options.Applicative (execParser)
import RIO hiding (error)
import RIO.Process
import Snowydeer.Container.Metadata
import Snowydeer.Container.Metadata.Types
import Snowydeer.Container.Opts
import Snowydeer.Container.Pipeline
import Snowydeer.Container.Types

#ifndef __OSS__
import Snowydeer.Container.Metadata.Mercury
#endif

-- | Object to be turned into a store path.
data InputPath
  = -- Resolved Buck target name in canonical form
    InputBuckTarget Text
  | -- | Nix store path that already exists
    InputStorePath StorePath
  deriving stock (Show, Ord, Eq)

instance A.FromJSON InputPath where
  parseJSON = A.withText "InputPath" \path ->
    pure $
      if "/nix/store" `T.isPrefixOf` path
        then
          InputStorePath . StorePath $ path
        else
          InputBuckTarget path

instance A.ToJSON InputPath where
  toJSON (InputBuckTarget t) = A.String t
  toJSON (InputStorePath p) = A.String p.unStorePath

-- | Build plan as viewed by Snowydeer Container.
--
-- Snowydeer Container needs to validate the metadata entries it is responsible
-- for validating, realize the buck targets in contents to Nix store paths, then
-- basically pass the rest of it to the Nix container builder.
--
-- The container builder is then run with `nix run` such that it uploads the
-- result to a registry.
--
-- See also @docs/buck2/deployment/snowydeer.md@.
data BuildPlan metadataType contentType = BuildPlan
  { name :: Text
  -- ^ Name of the image.
  , cmd :: [Text]
  -- ^ Command to run from the root of the image on startup.
  , env :: HashMap Text Text
  -- ^ Map of environment variables.
  , ports :: Set Text
  -- ^ Set of @9000/tcp@ like strings of ports to expose.
  , contents :: [contentType]
  -- ^ Contents of the image which will be auto-layered as the system sees fit
  -- (maybe all @contents@ go in the same layer, maybe not).
  --
  -- This is for miscellaneous dependencies which won't change without having
  -- to rebuild the entire image regardless, for example, utilities.
  , mainContents :: [contentType]
  -- ^ Contents of the image which will be forced into layers, each item by
  -- itself, with the dependencies auto-managed.
  --
  -- Prefer to put the important, fast-changing contents of the image in here
  -- so it can be layered optimally.
  , metadata :: metadataType
  -- ^ Metadata on the image in
  -- [OCI-compliant format](https://specs.opencontainers.org/image-spec/annotations/?v=v1.1.1).
  }
  deriving stock (Show, Eq)

buildPlanMetadataL :: Lens (BuildPlan metadataType contentType) (BuildPlan metadataType' contentType) metadataType metadataType'
buildPlanMetadataL = lens (.metadata) (\p v -> p {metadata = v})

buildPlanContentsL :: Lens' (BuildPlan _metadataType contentType) [contentType]
buildPlanContentsL = lens (.contents) (\p v -> p {contents = v})

$(A.deriveJSON A.defaultOptions ''BuildPlan)

data ExportBuildPlan = ExportBuildPlan
  { plan :: BuildPlan ValidMetadata StorePath
  , layeringPipeline :: [PipelineItem]
  }
  deriving stock (Show)

instance A.ToJSON ExportBuildPlan where
  toJSON ExportBuildPlan {..} = A.Object $ it'sAnObjectIPromise (A.toJSON plan) <> it'sAnObjectIPromise (A.object ["layeringPipeline" A..= layeringPipeline])
    where
      it'sAnObjectIPromise (A.Object o) = o
      it'sAnObjectIPromise _ = provideCallStack $ error "no really this is impossible"

realTargetsToNix :: [Text] -> AppM [StorePath]
realTargetsToNix targets = do
  let args = [arg | path <- targets, arg <- ["--target", path]]
  imported <-
    proc "buck" (["bxl", "//snowydeer/snowydeer.bxl:main", "--"] <> map T.unpack args) $
      fmap (T.lines . TE.decodeUtf8 . BS.toStrict) . readProcessStdout_
  forM imported (fmap (StorePath . T.strip) . liftIO . TIO.readFile . T.unpack)

-- | What Git revision is the repository on?
newtype GitRevInfo = GitRevInfo
  { revision :: Text
  }
  deriving stock (Show)

realGitRevInfo :: AppM GitRevInfo
realGitRevInfo = do
  revision <- proc "git" ["rev-parse", "HEAD"] $ fmap (T.strip . TE.decodeUtf8 . BS.toStrict) . readProcessStdout_
  pure $ GitRevInfo revision

attachGitInfo :: GitRevInfo -> UncheckedMetadata -> UncheckedMetadata
attachGitInfo GitRevInfo {revision} meta =
  meta <> HashMap.singleton "org.opencontainers.image.revision" revision

realizeTargets :: RequireCallStack => ([Text] -> AppM [StorePath]) -> BuildPlan meta InputPath -> AppM (BuildPlan meta StorePath)
realizeTargets targetsToNix plan = do
  -- Map target names (which may appear multiple times) to a single list of
  -- targets we give to build_store_path.
  let needTargets = HashSet.toList $ extractBuckTargets plan.contents <> extractBuckTargets plan.mainContents
  logInfo $ "To import to Nix: " <> displayShow needTargets

  builtPaths <- targetsToNix needTargets
  let mapping = HashMap.fromList $ zip needTargets builtPaths
  logDebug $ "Mapping: " <> displayShow mapping

  pure $ plan {contents = mapInput mapping <$> plan.contents, mainContents = mapInput mapping <$> plan.mainContents}
  where
    mapInput :: HashMap Text StorePath -> InputPath -> StorePath
    mapInput mapping (InputBuckTarget t) = fromMaybe (error ("bug: missing store path " <> show t)) $ HashMap.lookup t mapping
    mapInput _ (InputStorePath p) = p

    extractBuckTargets :: [InputPath] -> HashSet Text
    -- TODO: this is a really dumb obfuscated way of writing "give me all the things matching this variant" using MonadFail
    extractBuckTargets = HashSet.fromList . mapMaybe (\p -> do InputBuckTarget p' <- pure p; pure p')

type AppM = RIO App

data Stubs = Stubs
  { doTargetsToNix :: [Text] -> AppM [StorePath]
  , doGitRevInfo :: AppM GitRevInfo
  }

data App = App
  { logFunc :: LogFunc
  , processContext :: ProcessContext
  , stubs :: Stubs
  , config :: SnowydeerConfig
  }

instance HasLogFunc App where
  logFuncL = lens (.logFunc) (\a v -> a {logFunc = v})

instance HasProcessContext App where
  processContextL = lens (.processContext) (\a v -> a {processContext = v})

newtype AesonDecodeError = AesonDecodeError String
  deriving stock (Show)
  deriving anyclass (Exception)

asksStub :: (Stubs -> a) -> AppM a
asksStub extract = asks (extract . (.stubs))

buildRealPlan :: RequireCallStack => BuildPlan UncheckedMetadata InputPath -> AppM (BuildPlan ValidMetadata StorePath)
buildRealPlan plan = do
  config <- asks (.config)
  newMeta <- either throwWithCallStack pure $ validateMetadata config.extraValidators plan.metadata
  let validPlan = plan {metadata = newMeta}

  targetsToNix <- asksStub doTargetsToNix
  realPlan <- realizeTargets targetsToNix validPlan
  logDebug $ "Plan: " <> displayShow realPlan
  pure realPlan

data ImageBuildMode = Upload Text | BuildOnly
  deriving stock (Show)

nixBuildContainer :: RequireCallStack => ExportBuildPlan -> AppM StorePath
nixBuildContainer plan = do
  proc
    "nix"
    [ "build"
    , "-f"
    , "."
    , "--print-build-logs"
    , "--print-out-paths"
    , "pkgs.mercury.snowydeer.build-container"
    , "--argstr"
    , "buildPlanJSON"
    , planToArg plan
    ]
    $ fmap (StorePath . T.strip . TE.decodeUtf8 . BS.toStrict) . readProcessStdout_
  where
    planToArg = T.unpack . TE.decodeUtf8 . BS.toStrict . A.encode

data DockerImageId
  = DockerTag Text Text
  | DockerDigest Text Text
  deriving stock (Eq, Ord)

instance Display DockerImageId where
  textDisplay (DockerTag path tag) = "docker://" <> path <> ":" <> tag
  textDisplay (DockerDigest path digest) = "docker://" <> path <> "@" <> digest

uploadToRegistry :: FilePath -> StorePath -> Text -> [Text] -> AppM [DockerImageId]
uploadToRegistry skopeo streamer registryPath tags = do
  -- Very similar procedure to Lix's releng for containers:
  -- https://git.lix.systems/lix-project/lix/src/eecc4ff1c02586a75b43892a1aca3350f2caed27/releng/docker.xsh#L57
  digest <- withSystemTempFile "snowydeer-digest.txt" \digestFile h -> do
    hClose h
    proc (T.unpack streamer.unStorePath) [] \p -> intoPipe p \streamProc ->
      proc skopeo (regCopyArgs digestFile) \pp -> runProcess_ (fromPipe pp streamProc)

    liftIO $ TIO.readFile digestFile

  logInfo $ "Image digest: " <> display digest
  let createTags = fmap (DockerTag registryPath) tags
  let digestPath = DockerDigest registryPath digest
  mapConcurrently_ (createTag digestPath) createTags
  pure (digestPath : createTags)
  where
    intoPipe p = withProcessWait_ (setStdout createPipe p)
    fromPipe p pipeProc = p & setStdin (useHandleClose (getStdout pipeProc))

    -- --insecure-policy is "i don't wanna sign my container", which is
    -- accurate. i don't, right now. future work for someone in security?
    regCopyArgs digestFile =
      [ "copy"
      , "--insecure-policy"
      , "--digestfile"
      , digestFile
      , "docker-archive:/dev/stdin"
      , "docker://" <> T.unpack registryPath <> "@@unknown-digest@@"
      ]

    createTag source target = do
      proc
        skopeo
        ( T.unpack
            <$> [ "copy"
                , "--insecure-policy"
                , textDisplay source
                , textDisplay target
                ]
        )
        runProcess_

preprocessPlan :: Ord contentType => GitRevInfo -> BuildPlan UncheckedMetadata contentType -> BuildPlan UncheckedMetadata contentType
preprocessPlan gitInfo plan =
  over buildPlanMetadataL (attachGitInfo gitInfo)
    -- Prevent a footgun: if you omit something from contents that's in mainContents it will get in the image no matter what.
    . over buildPlanContentsL (\old -> ordNub (plan.mainContents <> old))
    $ plan

-- | Top level planning function. Takes a plan from the Buck rule and turns it
-- into an exportable plan ready for Nix to build.
planify :: RequireCallStack => GitRevInfo -> BuildPlan UncheckedMetadata InputPath -> AppM ExportBuildPlan
planify gitInfo plan0 = do
  let plan1 = preprocessPlan gitInfo plan0
  plan <- buildRealPlan plan1
  let pipeline = pipelineFor plan.mainContents

  pure ExportBuildPlan {layeringPipeline = pipeline, plan}

app :: Opts -> AppM ()
app opts = provideCallStack do
  gitInfo <- Monad.join (asksStub doGitRevInfo)
  planJson <-
    (either (throwWithCallStack . AesonDecodeError) pure)
      =<< liftIO (A.eitherDecodeFileStrict @(BuildPlan UncheckedMetadata InputPath) (T.unpack opts.buildPlan))

  plan <- planify gitInfo planJson

  storePath <- nixBuildContainer plan
  case opts.task of
    DoBuild -> pure ()
    -- Forces the docker-tarball-only import tag name to "latest" for good UX:
    -- you can rerun `podman run glean_container:latest` repeatedly without
    -- having to copy a hash.
    DoSave -> proc (T.unpack storePath.unStorePath) ["--repo_tag", T.unpack plan.plan.name <> ":latest"] runProcess_
    DoPush push -> do
      let tags = tagsFromGit gitInfo <> push.extraTags
      pushed <- uploadToRegistry opts.skopeoExe storePath push.registryLocation tags

      logInfo $ "Pushed:\n" <> display (T.unlines . fmap (("- " <>) . textDisplay) $ pushed)
  where
    tagsFromGit gitInfo = [gitInfo.revision]

realStubs :: Stubs
realStubs =
  Stubs
    { doTargetsToNix = realTargetsToNix
    , doGitRevInfo = realGitRevInfo
    }

defaultConfig :: SnowydeerConfig
#ifdef __OSS__
defaultConfig = mempty
#else
defaultConfig = mempty <> mercuryConfig
#endif

main :: IO ()
main = do
  opts <- execParser options

  logOpts <- logOptionsHandle stderr opts.verbose
  processContext <- mkDefaultProcessContext
  withLogFunc logOpts \logFunc ->
    runRIO (App {logFunc, processContext, stubs = realStubs, config = defaultConfig}) (app opts)
