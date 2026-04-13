-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# OPTIONS_GHC "-Wno-incomplete-uni-patterns" #-}

module Snowydeer.ContainerSpec (main) where

import A.MercuryPrelude.RequireCallStack hiding (error)
import Control.Monad qualified as Monad
import Data.Aeson qualified as A
import Data.Aeson.Types qualified as A
import Data.HashMap.Strict qualified as HashMap
import Data.Set qualified as Set
import Data.Text qualified as T
import RIO
import Snowydeer.Container hiding (main)
import Snowydeer.Container.Metadata.Types
import Snowydeer.Container.Types
import Test.Hspec

testApp :: App
testApp =
  App
    { processContext = error "don't use subprocesses in tests"
    , logFunc = mkLogFunc \_ _ _ _ -> pure ()
    , config = mempty
    , stubs =
        Stubs
          { doTargetsToNix = \targets -> pure $ StorePath . (\p -> "/nix/store/" <> buckToNixPath p) <$> targets
          , doGitRevInfo = pure GitRevInfo {revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
          }
    }
  where
    -- This is very much not a correct procedure but we can trick the code, it's ok.
    buckToNixPath = T.replace "/" "_" . T.replace ":" "_"

testPlan :: BuildPlan UncheckedMetadata InputPath
testPlan =
  BuildPlan
    { name = "service"
    , cmd = ["/bin/service"]
    , env = HashMap.fromList [("a", "b")]
    , ports = Set.fromList []
    , -- TODO: should mainContents be a strict superset of contents? probably, right? or should contents be called otherContents?
      contents = [InputBuckTarget "//foo/bar:tgt", InputStorePath "/nix/store/whatever-meow"]
    , mainContents = [InputBuckTarget "cell//bar/baz:blah"]
    , metadata = HashMap.fromList [("com.mercury.engineering.team", "BEDUX"), ("com.mercury.runbook.url", "https://example.com"), ("org.opencontainers.image.description", "foo")]
    }

testAppM :: (RequireCallStack => AppM a) -> IO a
testAppM = provideCallStack $ runRIO testApp

spec :: Spec
spec = describe "container builder" do
  it "translates contents to nix" $ testAppM do
    gitInfo <- Monad.join (asksStub doGitRevInfo)
    plan <- (.plan) <$> planify gitInfo testPlan
    -- deals with putting stuff in mainContents without putting it in contents
    liftIO $ plan.contents `shouldBe` ["/nix/store/cell__bar_baz_blah", "/nix/store/__foo_bar_tgt", "/nix/store/whatever-meow"]
    liftIO $ plan.mainContents `shouldBe` ["/nix/store/cell__bar_baz_blah"]

  it "has git metadata" $ testAppM do
    gitInfo <- Monad.join (asksStub doGitRevInfo)
    plan <- planify gitInfo testPlan
    let Just rev =
          view buildPlanMetadataL plan.plan & \meta ->
            HashMap.lookup "org.opencontainers.image.revision" meta.unValidMetadata
    liftIO $ rev `shouldBe` gitInfo.revision

  it "serializes the expected json for ExportBuildPlan" $ testAppM do
    gitInfo <- Monad.join (asksStub doGitRevInfo)
    plan <- planify gitInfo testPlan

    let j = A.toJSON plan
        Right planItself = A.parseEither (A.parseJSON @(BuildPlan UncheckedMetadata StorePath)) j
        -- Don't want to write a parser instance for pipelines as it might
        -- diverge. This test is rather unsatisfying as a result.
        Right layeringPipelineValue = A.parseEither (A.withObject "ExportBuildPlan" \v -> v A..: "layeringPipeline") j
        layeringPlan = A.toJSON plan.layeringPipeline
    liftIO $ planItself `shouldBe` (over buildPlanMetadataL (.unValidMetadata) plan.plan)
    liftIO $ layeringPlan `shouldBe` layeringPipelineValue

main :: IO ()
main = hspec spec
