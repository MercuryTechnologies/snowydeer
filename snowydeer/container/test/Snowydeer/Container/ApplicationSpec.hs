-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# LANGUAGE QuasiQuotes #-}
{-# OPTIONS_GHC "-Wno-incomplete-uni-patterns" #-}

module Snowydeer.Container.ApplicationSpec (main) where

import A.MercuryPrelude.RequireCallStack hiding (error)
import Control.Monad qualified as Monad
import Data.Aeson qualified as A
import Data.Aeson.Types qualified as A
import Data.HashMap.Strict qualified as HashMap
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import RIO
import RIO.Process (mkDefaultProcessContext)
import Snowydeer.Container.Application hiding (main)
import Snowydeer.Container.Metadata.Types
import System.Environment (lookupEnv)
import Test.Hspec
import Text.Shakespeare.Text (st)

testApp :: App
testApp =
  App
    { processContext = error "don't use subprocesses in tests"
    , logFunc = mkLogFunc \_ _ _ _ -> pure ()
    , config = mempty
    , stubs =
        Stubs
          { doGitRevInfo = pure GitRevInfo {revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
          , doNixPrefetchDocker = error "don't call nix-prefetch-docker in these tests"
          , doNixBuild = error "don't call nix build in these tests"
          }
    }

testPlan :: BuildPlan UncheckedMetadata
testPlan =
  BuildPlan
    { name = "service"
    , cmd = ["/bin/service"]
    , env = HashMap.fromList [("a", "b"), ("GIT_SHA1", "stale revision")]
    , ports = Set.fromList []
    , -- TODO: should mainContents be a strict superset of contents? probably, right? or should contents be called otherContents?
      contents = ["/nix/store/aaaa-tgt", "/nix/store/whatever-meow"]
    , mainContents = ["/nix/store/bbbb-blah"]
    , metadata = HashMap.fromList [("com.mercury.engineering.team", "BEDUX"), ("com.mercury.runbook.url", "https://example.com"), ("org.opencontainers.image.description", "foo")]
    , baseImage = Nothing
    }

testAppM :: (RequireCallStack => AppM a) -> IO a
testAppM = provideCallStack $ runRIO testApp

-- | Test stubs for 'updateBaseImage': returns canned 'PrefetchResult's keyed
-- by @(os, dockerArch)@. The @imageDigest@ is the same for all arches (a
-- multiarch manifest digest); only the nar hash differs.
fakeNixPrefetchDockerStubs :: Stubs
fakeNixPrefetchDockerStubs =
  Stubs
    { doGitRevInfo = error "not used in updateBaseImage"
    , doNixPrefetchDocker = \args ->
        case (args.os, args.dockerArch) of
          ("linux", "amd64") ->
            pure
              PrefetchResult
                { imageName = "test/image"
                , imageDigest = "sha256:newdigest"
                , hash = "sha256-newnarAmd64"
                , finalImageName = "test/image"
                , finalImageTag = "pinned"
                }
          ("linux", "arm64") ->
            pure
              PrefetchResult
                { imageName = "test/image"
                , imageDigest = "sha256:newdigest"
                , hash = "sha256-newnarArm64"
                , finalImageName = "test/image"
                , finalImageTag = "pinned"
                }
          other ->
            throwString $ "unexpected (os, dockerArch): " <> show other
    , doNixBuild = error "not used in updateBaseImage"
    }

-- | Build an 'App' with a real 'ProcessContext' for tests that exec subprocesses.
mkUpdateApp :: Stubs -> IO App
mkUpdateApp stubs = do
  processContext <- mkDefaultProcessContext
  pure
    App
      { processContext
      , logFunc = mkLogFunc \_ _ _ _ -> pure ()
      , config = mempty
      , stubs
      }

-- | BUCK file already containing the values that 'fakeNixPrefetchDockerStubs' returns,
-- so running updateBaseImage against it produces a buildozer no-op (exit code 3).
alreadyCurrentBuck :: Text
alreadyCurrentBuck =
  [st|snowydeer_base_image(
    name = "base",
    image_name = "test/image",
    follows_tag = "latest",
    digest = "sha256:newdigest",
    nar_hashes = {
        "aarch64-linux": "sha256-newnarArm64",
        "x86_64-linux": "sha256-newnarAmd64",
    },
)
|]

startingBuck :: Text
startingBuck =
  [st|snowydeer_base_image(
    name = "base",
    image_name = "test/image",
    follows_tag = "latest",
    digest = "sha256:olddigest",
    nar_hashes = {
        "aarch64-linux": "sha256-oldnarArm64",
        "x86_64-linux": "sha256-oldnarAmd64",
    },
)
|]

startingSpec :: FilePath -> BaseImageUpdateSpec
startingSpec buckPath =
  BaseImageUpdateSpec
    { imageName = "test/image"
    , followsTag = Just "latest"
    , -- buildozer accepts BUILD/BUCK file paths as labels: <abs-path>:<target>.
      label = T.pack (buckPath <> ":base")
    , activeSystem = "x86_64-linux"
    , imageDigest = "sha256:olddigest"
    , narHashes =
        HashMap.fromList
          [ ("x86_64-linux", "sha256-oldnarAmd64")
          , ("aarch64-linux", "sha256-oldnarArm64")
          ]
    }

spec :: Spec
spec = do
  describe "container builder" do
    it "folds mainContents into contents" $ testAppM do
      gitInfo <- Monad.join (asksStub doGitRevInfo)
      plan <- (.plan) <$> planify gitInfo testPlan
      -- deals with putting stuff in mainContents without putting it in contents
      liftIO $ plan.contents `shouldBe` ["/nix/store/bbbb-blah", "/nix/store/aaaa-tgt", "/nix/store/whatever-meow"]
      liftIO $ plan.mainContents `shouldBe` ["/nix/store/bbbb-blah"]

    it "has the git revision in metadata and the container environment" $ testAppM do
      gitInfo <- Monad.join (asksStub doGitRevInfo)
      plan <- planify gitInfo testPlan
      let Just rev =
            view buildPlanMetadataL plan.plan & \meta ->
              HashMap.lookup "org.opencontainers.image.revision" meta.unValidMetadata
      liftIO $ rev `shouldBe` gitInfo.revision
      liftIO $ HashMap.lookup "GIT_SHA1" plan.plan.env `shouldBe` Just gitInfo.revision

    it "serializes the expected json for ExportBuildPlan" $ testAppM do
      gitInfo <- Monad.join (asksStub doGitRevInfo)
      plan <- planify gitInfo testPlan

      let j = A.toJSON plan
          Right planItself = A.parseEither (A.parseJSON @(BuildPlan UncheckedMetadata)) j
          -- Don't want to write a parser instance for pipelines as it might
          -- diverge. This test is rather unsatisfying as a result.
          Right layeringPipelineValue = A.parseEither (A.withObject "ExportBuildPlan" \v -> v A..: "layeringPipeline") j
          layeringPlan = A.toJSON plan.layeringPipeline
      liftIO $ planItself `shouldBe` (over buildPlanMetadataL (.unValidMetadata) plan.plan)
      liftIO $ layeringPlan `shouldBe` layeringPipelineValue

    it "passes a base image through planify unchanged" $ testAppM do
      gitInfo <- Monad.join (asksStub doGitRevInfo)
      let base =
            BaseImageSpec
              { imageName = "someregistry.com/jetbrains/youtrack"
              , system = "x86_64-linux"
              , imageDigest = "sha256:abc"
              , narHash = "sha256-abc"
              }
      plan <- (.plan) <$> planify gitInfo testPlan {baseImage = Just base}
      liftIO $ plan.baseImage `shouldBe` Just base

  describe "updateBaseImage" do
    it "writes new digests and nar_hashes into the BUCK file via buildozer" do
      buildozerExe <-
        lookupEnv "BUILDOZER"
          >>= maybe
            ( fail $
                "missing BUILDOZER env-var; "
                  <> "add env = {\"BUILDOZER\": \"$(exe toolchains//:buildifier[buildozer])\"} "
                  <> "to the application_spec target in test/Snowydeer/Container/BUCK"
            )
            pure
      app <- mkUpdateApp fakeNixPrefetchDockerStubs
      withSystemTempDirectory "snowydeer-update" \dir -> do
        let buckPath = dir <> "/BUCK"
            specPath = dir <> "/spec.json"
        TIO.writeFile buckPath startingBuck
        liftIO $ A.encodeFile specPath (startingSpec buckPath)
        runRIO app (updateBaseImage buildozerExe specPath)
        new <- TIO.readFile buckPath
        -- Positive: new digest and nar_hashes from the fake stub
        new `shouldSatisfy` T.isInfixOf "sha256:newdigest"
        new `shouldSatisfy` T.isInfixOf "sha256-newnarAmd64"
        new `shouldSatisfy` T.isInfixOf "sha256-newnarArm64"
        -- Negative: old values should be absent
        new `shouldNotSatisfy` T.isInfixOf "sha256:olddigest"
        new `shouldNotSatisfy` T.isInfixOf "sha256-oldnarAmd64"
        new `shouldNotSatisfy` T.isInfixOf "sha256-oldnarArm64"

    it "succeeds without error when buildozer makes no changes (exit code 3)" do
      buildozerExe <-
        lookupEnv "BUILDOZER"
          >>= maybe
            ( fail $
                "missing BUILDOZER env-var; "
                  <> "add env = {\"BUILDOZER\": \"$(exe toolchains//:buildifier[buildozer])\"} "
                  <> "to the application_spec target in test/Snowydeer/Container/BUCK"
            )
            pure
      app <- mkUpdateApp fakeNixPrefetchDockerStubs
      withSystemTempDirectory "snowydeer-update" \dir -> do
        let buckPath = dir <> "/BUCK"
            specPath = dir <> "/spec.json"
        -- Start with values that already match what the stub returns, so buildozer is a no-op.
        TIO.writeFile buckPath alreadyCurrentBuck
        liftIO $ A.encodeFile specPath (startingSpec buckPath)
        runRIO app (updateBaseImage buildozerExe specPath)

  describe "validateBaseImage" do
    it "validates every pinned arch, not just the active one" do
      systemsRef <- newIORef ([] :: [Text])
      let stubs =
            testApp.stubs
              { doNixBuild = \_ argstrs -> do
                  liftIO $ modifyIORef systemsRef (maybe id (:) (HashMap.lookup "system" argstrs))
                  pure ""
              }
      withSystemTempDirectory "snowydeer-validate" \dir -> do
        let specPath = dir <> "/spec.json"
            outPath = dir <> "/out.txt"
        A.encodeFile specPath (startingSpec "/fakepath/BUCK")
        runRIO testApp {stubs} (validateBaseImage specPath outPath)
        systems <- readIORef systemsRef
        Set.fromList systems `shouldBe` Set.fromList ["x86_64-linux", "aarch64-linux"]

main :: IO ()
main = hspec spec
