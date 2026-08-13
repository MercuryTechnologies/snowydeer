-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | End-to-end snowydeer container integration test.
--
-- Builds the @//snowydeer/demo:hello_container@ tarball via the snowydeer
-- binary, loads it into a hermetic 'PodmanSandbox', runs the resulting
-- container, and asserts its output and embedded OCI metadata.
module Snowydeer.Container.E2ESpec (main, spec) where

import Data.Aeson ((.:))
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.HashMap.Strict qualified as HashMap
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import RIO
import RIO.FilePath ((</>))
import RIO.Process
import Snowydeer.Container.E2E.PodmanSandbox
import System.Environment (getEnv)
import Test.Hspec

data TestEnv = TestEnv
  { processContext :: ProcessContext
  , logFunc :: LogFunc
  }

instance HasProcessContext TestEnv where
  processContextL = lens (.processContext) (\e v -> e {processContext = v})

instance HasLogFunc TestEnv where
  logFuncL = lens (.logFunc) (\e v -> e {logFunc = v})

mkTestEnv :: IO TestEnv
mkTestEnv = do
  pc <- mkDefaultProcessContext
  pure TestEnv {processContext = pc, logFunc = mkLogFunc \_ _ _ _ -> pure ()}

runE2E :: RIO TestEnv a -> IO a
runE2E action = do
  env <- mkTestEnv
  runRIO env action

-- | Image tag produced by @<container> save@ per "Snowydeer.Container"
helloImageRef :: Text
helloImageRef = "localhost/hello_container:latest"

-- | Wrapper around `podman inspect <image> | jq '.[0].Config.Labels'` decoded
-- as a Text->Text map.
newtype InspectResult = InspectResult {labels :: HashMap Text Text}
  deriving stock (Show)

instance A.FromJSON InspectResult where
  parseJSON = A.withObject "InspectEntry" \o -> do
    config <- o .: "Config"
    InspectResult <$> config .: "Labels"

-- | Fake Git hash, for determinism purposes (and to not require running in a
-- git repo).
fakeGitHash :: Text
fakeGitHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

-- | Build the demo container as a tarball into @target@.
buildHelloTarball :: FilePath -> FilePath -> RIO TestEnv ()
buildHelloTarball helloExe target = do
  bytes <-
    withModifyEnvVars (Map.insert "SNOWYDEER_TEST_GIT_SHA1" fakeGitHash) $
      proc helloExe ["save"] readProcessStdout_
  liftIO $ LBS.writeFile target bytes

spec :: Spec
spec = describe "snowydeer container e2e" do
  it "builds, loads, and runs the demo hello container" $ do
    podmanExe <- getEnv "PODMAN_BIN"
    helloExe <- getEnv "HELLO_CONTAINER"
    runE2E $ withSystemTempDirectory "snowydeer-e2e" \workDir -> do
      let tarballPath = workDir </> "hello.tar"
      buildHelloTarball helloExe tarballPath

      withPodmanSandbox podmanExe \sandbox -> do
        -- Load image from tarball
        loadOut <-
          podmanProc sandbox ["load", "-i", T.pack tarballPath] $
            fmap LBS.toStrict . readProcessStdout_
        liftIO $
          ("Loaded image" `BS.isInfixOf` loadOut) `shouldBe` True

        -- Run the container; expect "Hello world" on stdout (see
        -- snowydeer/demo/Hello.hs).
        runOut <-
          podmanProc sandbox ["run", "--rm", "--network=none", helloImageRef] $
            fmap LBS.toStrict . readProcessStdout_
        liftIO $
          T.strip (TE.decodeUtf8 runOut) `shouldBe` "Hello world"

        -- Inspect labels; assert the snowydeer-generated revision label is
        -- present (validates the planify → metadata path end-to-end).
        inspectOut <- podmanProc sandbox ["inspect", helloImageRef] readProcessStdout_
        resultList <- A.throwDecode @[InspectResult] inspectOut
        -- FIXME(jadel): this is assertOneElement in mercury-hspec-assertions, but we first need to open source that.
        liftIO $ case resultList of
          [result] -> result.labels `shouldSatisfy` HashMap.member "org.opencontainers.image.revision"
          wrong -> expectationFailure $ "more than one item in list: " <> show wrong

main :: IO ()
main = hspec spec
