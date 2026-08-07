{-# LANGUAGE CPP #-}
-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Container builder for Snowydeer.
--
-- This calls Snowydeer on the buck targets that need it, produces the store
-- paths, then passes those into the Nix docker builder.
module Snowydeer.Container.Application
  ( -- * Build plans
    InputPath (..),
    BaseImageSpec (..),
    GitRevInfo (..),
    BuildPlan (..),
    buildPlanMetadataL,
    buildPlanContentsL,
    ExportBuildPlan (..),

    -- * Base image update spec
    BaseImageUpdateSpec (..),
    ImageRef (..),
    NixPrefetchDockerArgs (..),
    PrefetchResult (..),

    -- * Building a plan
    planify,

    -- * Base image update
    validateBaseImage,
    updateBaseImage,
    lockBaseImage,

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
import Snowydeer.Container.Metadata.Types
import Snowydeer.Container.Metadata.Validation
import Snowydeer.Container.Opts
import Snowydeer.Container.Pipeline
import Snowydeer.Container.Types

#ifndef __OSS__
import Snowydeer.Container.Mercury
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

-- | A pinned third-party base image to build a container on top of.
--
-- Pure passthrough from the @snowydeer_base_image@ Buck rule to the Nix
-- container builder, which turns it into @streamLayeredImage@'s @fromImage@ via
-- @dockerTools.pullImage@. The pin is already resolved to the active
-- architecture; @system@ (the Nix system double, e.g. @x86_64-linux@) lets the
-- Nix side derive the Docker os/arch.
data BaseImageSpec = BaseImageSpec
  { imageName :: Text
  -- ^ Registry path, e.g. @someregistry.com/jetbrains/youtrack@.
  , system :: Text
  -- ^ Nix system double, e.g. @x86_64-linux@.
  , imageDigest :: Text
  -- ^ OCI image digest, @sha256:…@.
  , narHash :: Text
  -- ^ SRI nar hash (@sha256-…@), serialized as @hash@ to match
  -- @nix-prefetch-docker@ / @dockerTools.pullImage@.
  }
  deriving stock (Show, Eq)

$( A.deriveJSON
     A.defaultOptions {A.fieldLabelModifier = \f -> if f == "narHash" then "hash" else f}
     ''BaseImageSpec
 )

-- | The update/validate spec written by the @snowydeer_base_image@ Buck rule
-- as @base_image_spec.json@. Contains a single digest for a multiarch image
-- (hash of the manifest listing all the per-arch digests) and per-arch NAR
-- hashes (the pulled content differs by arch).
data BaseImageUpdateSpec = BaseImageUpdateSpec
  { imageName :: Text
  , followsTag :: Maybe Text
  , label :: Text
  -- ^ Buck target label, e.g. @root//snowydeer/demo:base@.  Used by buildozer.
  , activeSystem :: Text
  , imageDigest :: Text
  -- ^ OCI manifest-list digest, @sha256:…@.  One value for all arches.
  , narHashes :: HashMap Text Text
  -- ^ Per-arch SRI nar hashes keyed by Nix system double, e.g. @x86_64-linux@.
  }
  deriving stock (Show, Eq)

$(A.deriveJSON A.defaultOptions ''BaseImageUpdateSpec)

-- | Output from @nix-prefetch-docker --json@.
data PrefetchResult = PrefetchResult
  { imageName :: Text
  , imageDigest :: Text
  , hash :: Text
  -- ^ SRI nar hash, @sha256-…@.
  , finalImageName :: Text
  , finalImageTag :: Text
  }
  deriving stock (Show, Eq)

$(A.deriveJSON A.defaultOptions ''PrefetchResult)

data ImageRef
  = -- | Fetch by tag (for @update@).
    ImageTag Text
  | -- | Fetch by digest (for @lock@; updates the NAR hash for the pinned digest).
    ImageDigest Text
  deriving stock (Show, Eq)

-- | Arguments for a @nix-prefetch-docker@ invocation.
data NixPrefetchDockerArgs = NixPrefetchDockerArgs
  { os :: Text
  , dockerArch :: Text
  , imageName :: Text
  , imageRef :: ImageRef
  }
  deriving stock (Show, Eq)

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
  , baseImage :: Maybe BaseImageSpec
  -- ^ Optional pinned third-party base image to build on top of. Absent for
  -- ordinary first-party images; passed through to the Nix container builder
  -- when present.
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
  , doNixPrefetchDocker :: NixPrefetchDockerArgs -> AppM PrefetchResult
  , doNixBuild :: Text -> HashMap Text Text -> AppM LByteString
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

nixBuildContainer :: ExportBuildPlan -> AppM StorePath
nixBuildContainer plan = do
  out <- nixBuild "pkgs.mercury.snowydeer.build-container" (HashMap.singleton "buildPlanJSON" planJson)
  pure . StorePath . T.strip . TE.decodeUtf8 . BS.toStrict $ out
  where
    planJson = TE.decodeUtf8 . BS.toStrict . A.encode $ plan

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
preprocessPlan gitInfo@GitRevInfo {revision} plan =
  over buildPlanMetadataL (attachGitInfo gitInfo)
    -- Prevent a footgun: if you omit something from contents that's in mainContents it will get in the image no matter what.
    . over buildPlanContentsL (\old -> ordNub (plan.mainContents <> old))
    $ plan {env = HashMap.insert "GIT_SHA1" revision plan.env}

-- | Top level planning function. Takes a plan from the Buck rule and turns it
-- into an exportable plan ready for Nix to build.
planify :: RequireCallStack => GitRevInfo -> BuildPlan UncheckedMetadata InputPath -> AppM ExportBuildPlan
planify gitInfo plan0 = do
  let plan1 = preprocessPlan gitInfo plan0
  plan <- buildRealPlan plan1
  let pipeline = pipelineFor plan.mainContents

  pure ExportBuildPlan {layeringPipeline = pipeline, plan}

findRepoRoot :: AppM FilePath
findRepoRoot = T.unpack . T.strip . decodeUtf8Lenient . toStrictBytes <$> proc "buck" ["root"] readProcessStdout_

-- | Parses a file and throws if there's a problem with it
throwDecodeFileStrict :: A.FromJSON a => FilePath -> IO a
throwDecodeFileStrict p =
  A.eitherDecodeFileStrict p
    >>= either (throwString . (("problem decoding file " <> p <> ": ") <>)) pure

-- | Derive Docker (os, arch) pull coordinates from a Nix system double.
-- FIXME(jadel): there's a bunch of duplication of this data including in both
-- pull-base-image.nix and build-container.nix.
--
-- @
-- "x86_64-linux" -> ("linux", "amd64")
-- "aarch64-linux" -> ("linux", "arm64")
-- @
archOf :: Text -> Either String (Text, Text)
archOf sys = case T.splitOn "-" sys of
  [arch, os] -> case arch of
    "x86_64" -> Right (os, "amd64")
    "aarch64" -> Right (os, "arm64")
    _ -> Left $ "unknown arch in system double: " <> T.unpack sys
  _ -> Left $ "invalid Nix system double: " <> T.unpack sys

-- | Run `nix build -f . <attr>` with @--argstr@ pairs; returns stdout.
nixBuild :: Text -> HashMap Text Text -> AppM LByteString
nixBuild attr argstrs =
  proc "nix" (["build", "-f", ".", "--print-build-logs", "--print-out-paths", T.unpack attr] <> flatArgstrs) readProcessStdout_
  where
    flatArgstrs = concatMap (\(k, v) -> ["--argstr", T.unpack k, T.unpack v]) (HashMap.toList argstrs)

-- | Pull every pinned arch from a @base_image_spec.json@.
-- Runs `nix build pkgs.mercury.snowydeer.pull-base-image` for each pin; a hash
-- mismatch or unresolvable digest makes nix fail, propagating the error. Writes
-- the @--out@ marker file on full success so Buck knows the action completed.
validateBaseImage :: FilePath -> FilePath -> AppM ()
validateBaseImage specPath outPath = do
  spec <- liftIO (throwDecodeFileStrict @BaseImageUpdateSpec specPath)
  when (HashMap.null spec.narHashes) $
    throwString $
      "narHashes is empty for " <> T.unpack spec.label <> "; add at least one arch to the snowydeer_base_image rule with empty hash then run `buck run " <> T.unpack spec.label <> " -- lock`"
  nixBuild' <- asksStub doNixBuild
  forM_ (HashMap.toList spec.narHashes) \(system, narHash) -> do
    logInfo $ "Validating pin for " <> display system
    void $
      nixBuild'
        "pkgs.mercury.snowydeer.pull-base-image"
        (HashMap.fromList [("imageName", spec.imageName), ("imageDigest", spec.imageDigest), ("hash", narHash), ("system", system)])
  liftIO $ TIO.writeFile outPath "OK\n"

realNixPrefetchDocker :: FilePath -> NixPrefetchDockerArgs -> AppM PrefetchResult
realNixPrefetchDocker nixPrefetchDockerExe args = do
  resultLbs <-
    proc
      nixPrefetchDockerExe
      ( [ "--os"
        , T.unpack args.os
        , "--arch"
        , T.unpack args.dockerArch
        , "--image-name"
        , T.unpack args.imageName
        ]
          <> refArgs args.imageRef
          <> [ "--final-image-name"
             , T.unpack args.imageName
             , "--final-image-tag"
             , "pinned"
             , "--json"
             ]
      )
      readProcessStdout_
  either (throwString . ("nix-prefetch-docker: bad output: " <>)) pure $
    A.eitherDecode @PrefetchResult resultLbs
  where
    refArgs (ImageTag tag) = ["--image-tag", T.unpack tag]
    refArgs (ImageDigest digest) = ["--image-digest", T.unpack digest]

-- | Fetch every arch via @doNixPrefetchDocker@ and write
-- @nar_hashes@.
--
-- When @imageRef@ is 'ImageTag', also writes @digest@ corresponding to a new
-- version of the tag; 'ImageDigest' leaves it alone.
pinBaseImage :: FilePath -> BaseImageUpdateSpec -> ImageRef -> AppM ()
pinBaseImage buildozerExe spec imageRef = do
  when (HashMap.null spec.narHashes) $
    throwString "narHashes is empty; add at least one arch to the snowydeer_base_image rule"

  nixPrefetchDocker <- asksStub doNixPrefetchDocker
  repoRoot <- findRepoRoot

  results <- forConcurrently (HashMap.toList spec.narHashes) \(system, _) -> do
    (os, dockerArch) <- either throwString pure (archOf system)
    logInfo $ "Fetching pin for " <> display system
    result <- nixPrefetchDocker NixPrefetchDockerArgs {os, dockerArch, imageName = spec.imageName, imageRef}
    pure (system, result)

  let narHashCmds = ["dict_set nar_hashes " <> system <> ":" <> result.hash | (system, result) <- results]
  digestCmds <- case imageRef of
    ImageTag _ -> do
      let digests = ordNub $ map ((.imageDigest) . snd) results
      case digests of
        [d] -> pure ["set digest \"" <> d <> "\""]
        _ -> throwString $ "per-arch digests disagree for " <> T.unpack spec.label <> " (expected a single manifest-list digest): " <> T.unpack (T.intercalate ", " digests)
    ImageDigest _ -> pure []
  let cmds = map T.unpack (narHashCmds <> digestCmds)

  exitCode <- proc buildozerExe (["-root_dir", repoRoot] <> cmds <> [T.unpack spec.label]) runProcess
  case exitCode of
    ExitSuccess -> pure ()
    ExitFailure 3 -> pure () -- buildozer exit 3 means no-op (nothing changed)
    ExitFailure n -> throwString $ "buildozer exited with code " <> show n

updateBaseImage :: FilePath -> FilePath -> AppM ()
updateBaseImage buildozerExe specPath = do
  spec <- liftIO (throwDecodeFileStrict @BaseImageUpdateSpec specPath)
  followsTag <- case spec.followsTag of
    Nothing -> throwString "update: followsTag is required; set it in the snowydeer_base_image rule"
    Just t -> pure t
  pinBaseImage buildozerExe spec (ImageTag followsTag)

lockBaseImage :: FilePath -> FilePath -> AppM ()
lockBaseImage buildozerExe specPath = do
  spec <- liftIO (throwDecodeFileStrict @BaseImageUpdateSpec specPath)
  when (T.null spec.imageDigest) $
    throwString "lock: imageDigest is empty; run update first or set it manually"
  pinBaseImage buildozerExe spec (ImageDigest spec.imageDigest)

app :: Opts -> AppM ()
app opts = provideCallStack do
  case opts.subcommand of
    BaseImage specPath DoUpdateBaseImage ->
      updateBaseImage opts.buildozerExe specPath
    BaseImage specPath DoLockBaseImage ->
      lockBaseImage opts.buildozerExe specPath
    BaseImage specPath (DoValidateBaseImage outPath) ->
      validateBaseImage specPath outPath
    Builder buildPlan DoBuild ->
      void (buildContainer buildPlan)
    Builder buildPlan DoSave -> do
      (plan, _, storePath) <- buildContainer buildPlan
      -- Forces the docker-tarball-only import tag name to "latest" for good UX:
      -- you can rerun `podman run glean_container:latest` repeatedly without
      -- having to copy a hash.
      proc (T.unpack storePath.unStorePath) ["--repo_tag", T.unpack plan.plan.name <> ":latest"] runProcess_
    Builder buildPlan (DoPush push) -> do
      (_, gitInfo, storePath) <- buildContainer buildPlan
      let tags = tagsFromGit gitInfo <> push.extraTags
      pushed <- uploadToRegistry opts.skopeoExe storePath push.registryLocation tags
      logInfo $ "Pushed:\n" <> display (T.unlines . fmap (("- " <>) . textDisplay) $ pushed)
  where
    tagsFromGit gitInfo = [gitInfo.revision]
    buildContainer buildPlan = provideCallStack do
      gitInfo <- Monad.join (asksStub doGitRevInfo)
      planJson <-
        (either (throwWithCallStack . AesonDecodeError) pure)
          =<< liftIO (A.eitherDecodeFileStrict @(BuildPlan UncheckedMetadata InputPath) buildPlan)
      plan <- planify gitInfo planJson
      storePath <- nixBuildContainer plan
      pure (plan, gitInfo, storePath)

realStubs :: FilePath -> Stubs
realStubs nixPrefetchDockerExe =
  Stubs
    { doTargetsToNix = realTargetsToNix
    , doGitRevInfo = realGitRevInfo
    , doNixPrefetchDocker = realNixPrefetchDocker nixPrefetchDockerExe
    , doNixBuild = nixBuild
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
    runRIO (App {logFunc, processContext, stubs = realStubs opts.nixPrefetchDockerExe, config = defaultConfig}) (app opts)
