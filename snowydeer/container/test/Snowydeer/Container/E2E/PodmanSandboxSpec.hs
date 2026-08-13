-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | Library-level tests for 'Snowydeer.Container.E2E.PodmanSandbox'.
--
-- Exercises sandbox isolation alone — does not depend on snowydeer container
-- code. Verifies that config files land in the tempdir, that podman picks up
-- the sandbox env (graphroot, registries), and that nested sandboxes don't
-- share state.
module Snowydeer.Container.E2E.PodmanSandboxSpec (main, spec) where

import Data.Aeson ((.:), (.:?))
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import RIO
import RIO.Directory (doesFileExist)
import RIO.FilePath ((</>))
import RIO.Process
import Snowydeer.Container.E2E.PodmanSandbox
import System.Environment (getEnv)
import Test.Hspec

-- | Minimal subset of `podman info --format json` output we care about.
newtype PodmanInfo = PodmanInfo {store :: PodmanStore}

newtype PodmanStore = PodmanStore {graphRoot :: Text}

instance A.FromJSON PodmanInfo where
  parseJSON = A.withObject "PodmanInfo" \o -> PodmanInfo <$> o .: "store"

instance A.FromJSON PodmanStore where
  parseJSON = A.withObject "PodmanStore" \o -> PodmanStore <$> o .: "graphRoot"

-- | Minimal subset of one entry of `podman images --format json`.
newtype PodmanImage = PodmanImage {names :: [Text]}
  deriving stock (Eq, Show)

instance A.FromJSON PodmanImage where
  -- Names is null rather than [] for untagged images.
  parseJSON = A.withObject "PodmanImage" \o ->
    PodmanImage . fromMaybe [] <$> o .:? "Names"

-- | Minimal env carrying just the capabilities 'withPodmanSandbox' needs.
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
  -- Silence logs to keep test output tidy. Switch to logOptionsHandle stderr
  -- True when debugging.
  pure TestEnv {processContext = pc, logFunc = mkLogFunc \_ _ _ _ -> pure ()}

runE2E :: RIO TestEnv a -> IO a
runE2E action = do
  env <- mkTestEnv
  runRIO env action

-- | Read podman path from PODMAN_BIN env var (set by BUCK as $(exe ...)).
getPodmanExe :: IO FilePath
getPodmanExe = getEnv "PODMAN_BIN"

-- | Images visible in a sandbox's graph root.
listImages :: PodmanSandbox -> RIO TestEnv [PodmanImage]
listImages sandbox = do
  out <- podmanProc sandbox ["images", "--format", "json"] readProcessStdout_
  A.throwDecode out

-- | Tag of the throwaway image used to prove sandboxes don't share storage.
isolationProbeRef :: Text
isolationProbeRef = "localhost/isolation-probe:latest"

-- | Two 512-byte zero blocks are a valid empty tar archive, which is enough
-- for @podman import@ to synthesise an image without touching the network.
writeEmptyTar :: MonadIO m => FilePath -> m ()
writeEmptyTar path = liftIO $ LBS.writeFile path (LBS.replicate 1024 0)

spec :: Spec
spec = describe "PodmanSandbox" do
  it "creates the expected config files in the tempdir" $ do
    podmanExe <- getPodmanExe
    runE2E $ withPodmanSandbox podmanExe \sandbox -> do
      let containersConfDir = sandboxRoot sandbox </> "home" </> ".config" </> "containers"
      forM_
        ["policy.json", "storage.conf", "registries.conf", "containers.conf"]
        \f -> do
          exists <- doesFileExist (containersConfDir </> f)
          liftIO $ exists `shouldBe` True

  it "runs `podman --version` successfully" $ do
    podmanExe <- getPodmanExe
    runE2E $ withPodmanSandbox podmanExe \sandbox -> do
      out <-
        podmanProc sandbox ["--version"] $
          fmap LBS.toStrict . readProcessStdout_
      liftIO $ ("podman version " `BS.isPrefixOf` out) `shouldBe` True

  it "reports the sandbox graphroot from `podman info`" $ do
    podmanExe <- getPodmanExe
    runE2E $ withPodmanSandbox podmanExe \sandbox -> do
      out <- podmanProc sandbox ["info", "--format", "json"] readProcessStdout_
      info <- A.throwDecode @PodmanInfo out
      liftIO $ graphRoot (store info) `shouldBe` T.pack (sandboxRoot sandbox </> "storage")

  it "isolates two sandboxes from each other" $ do
    podmanExe <- getPodmanExe
    runE2E $ withSystemTempDirectory "snowydeer-isolation" \workDir -> do
      let tarball = workDir </> "empty.tar"
      writeEmptyTar tarball
      withPodmanSandbox podmanExe \s1 -> do
        _ <- podmanProc s1 ["import", T.pack tarball, isolationProbeRef] readProcessStdout_
        s1Images <- listImages s1
        liftIO $
          concatMap (.names) s1Images `shouldBe` [isolationProbeRef]
        -- The nested sandbox has its own graph root, so it must not see the
        -- image s1 just imported.
        withPodmanSandbox podmanExe \s2 -> do
          s2Images <- listImages s2
          liftIO $ s2Images `shouldBe` []

main :: IO ()
main = hspec spec
