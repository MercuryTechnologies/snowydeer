-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | Hermetic podman sandbox for integration tests.
--
-- Running podman against a user's real @~/.config/containers@ and shared graph
-- root leaks state between tests and depends on host setup. This module
-- provides 'withPodmanSandbox', a bracket that puts every bit of podman state
-- (config, policy, graph root, runtime dir) inside a tempdir and exposes a
-- 'podmanProc' helper that runs podman with the corresponding env applied.
module Snowydeer.Container.E2E.PodmanSandbox
  ( PodmanSandbox (..),
    withPodmanSandbox,
    podmanProc,
    podmanEnv,
    withSandboxedEnv,
  )
where

import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import RIO
import RIO.Directory (createDirectoryIfMissing)
import RIO.FilePath ((</>))
import RIO.Process

-- | A live podman sandbox: a tempdir laid out for hermetic invocation.
data PodmanSandbox = PodmanSandbox
  { sandboxRoot :: FilePath
  -- ^ Root of the sandbox tempdir; cleaned up when 'withPodmanSandbox' exits.
  , podmanExe :: FilePath
  -- ^ Absolute path to the podman binary.
  }
  deriving stock (Show)

-- | Bracketed sandbox. Creates the tempdir, lays out config, runs the action
-- with sandbox env applied, then best-effort calls @podman system reset
-- --force@ and removes the tempdir.
withPodmanSandbox ::
  (HasProcessContext env, HasLogFunc env) =>
  -- | Absolute path to the podman binary.
  FilePath ->
  (PodmanSandbox -> RIO env a) ->
  RIO env a
withPodmanSandbox podmanExe action =
  withSystemTempDirectory "snowydeer-podman-sandbox" \root -> do
    _ <- createSandbox root
    let sandbox = PodmanSandbox {sandboxRoot = root, podmanExe}
    action sandbox `finally` resetSandbox sandbox

-- | Env vars that must be set when invoking podman against the sandbox. Also
-- usable for related tools (e.g. skopeo) that respect @CONTAINERS_*@ and the
-- XDG variables.
podmanEnv :: PodmanSandbox -> [(Text, Text)]
podmanEnv PodmanSandbox {sandboxRoot} =
  let SandboxLayout {home, config, dataDir, runtime, containersConfDir, tmp} =
        sandboxLayout sandboxRoot
   in mapBoth
        T.pack
        [ ("HOME", home)
        , ("XDG_CONFIG_HOME", config)
        , ("XDG_DATA_HOME", dataDir)
        , ("XDG_RUNTIME_DIR", runtime)
        , ("CONTAINERS_CONF", containersConfDir </> "containers.conf")
        , ("CONTAINERS_STORAGE_CONF", containersConfDir </> "storage.conf")
        , ("CONTAINERS_REGISTRIES_CONF", containersConfDir </> "registries.conf")
        , ("TMPDIR", tmp)
        ]
  where
    mapBoth f = map (\(a, b) -> (f a, f b))

-- | Run an action with the sandbox's env vars merged into the
-- 'ProcessContext'. Sandbox vars override host vars on conflict.
withSandboxedEnv ::
  (HasProcessContext env) =>
  PodmanSandbox ->
  RIO env a ->
  RIO env a
withSandboxedEnv sandbox inner = do
  pc <- view processContextL
  let merged = Map.union (Map.fromList (podmanEnv sandbox)) (view envVarsL pc)
  pc' <- mkProcessContext merged
  local (set processContextL pc') inner

-- | Build a podman 'ProcessConfig' with sandbox env applied, then run the
-- continuation with it.
podmanProc ::
  (HasProcessContext env, HasLogFunc env) =>
  PodmanSandbox ->
  [Text] ->
  (ProcessConfig () () () -> RIO env a) ->
  RIO env a
podmanProc sandbox args k =
  withSandboxedEnv sandbox $ proc (podmanExe sandbox) (map T.unpack args) k

-- internals -----------------------------------------------------------------

-- | All sandbox-internal paths derived from the tempdir root.
data SandboxLayout = SandboxLayout
  { home :: FilePath
  , config :: FilePath
  , dataDir :: FilePath
  , dataContainers :: FilePath
  , runtime :: FilePath
  , containersConfDir :: FilePath
  , storage :: FilePath
  , tmp :: FilePath
  }

-- | Creates a layout, without creating the directories for it.
sandboxLayout :: FilePath -> SandboxLayout
sandboxLayout root =
  let home = root </> "home"
      config = home </> ".config"
      dataDir = home </> ".local" </> "share"
   in SandboxLayout
        { home
        , config
        , dataDir
        , dataContainers = dataDir </> "containers"
        , runtime = root </> "runroot"
        , containersConfDir = config </> "containers"
        , storage = root </> "storage"
        , tmp = root </> "tmp"
        }

createSandbox :: MonadIO m => FilePath -> m SandboxLayout
createSandbox root = liftIO do
  let layout = sandboxLayout root
  let SandboxLayout {dataContainers, runtime, containersConfDir, storage, tmp} = layout
  mapM_
    (createDirectoryIfMissing True)
    [containersConfDir, dataContainers, storage, runtime, tmp]
  -- Permissive policy: accept any image without signature verification.
  -- We're not going to sign things for testing.
  LBS.writeFile (containersConfDir </> "policy.json") $
    A.encode $
      A.object ["default" A..= [A.object ["type" A..= A.String "insecureAcceptAnything"]]]
  -- Storage uses vfs driver: overlay needs fuse-overlayfs or kernel support
  -- that may not be present rootless in CI. vfs is slower but simpler.
  -- `rootless_storage_path` is the field rootless podman actually reads;
  -- `graphroot` is for root-mode podman. Set both so the sandbox works
  -- regardless of how podman is invoked.
  --
  -- FIXME(jadel): this is a bad/wrong serializer for toml. i don't like it,
  -- but we don't have a haskell toml library in-tree yet.
  writeText (containersConfDir </> "storage.conf") $
    T.unlines
      [ "[storage]"
      , "driver = \"vfs\""
      , "graphroot = \"" <> T.pack storage <> "\""
      , "rootless_storage_path = \"" <> T.pack storage <> "\""
      , "runroot = \"" <> T.pack runtime <> "\""
      ]
  -- Empty registries to prevent any accidental network pulls.
  writeText (containersConfDir </> "registries.conf") $
    T.unlines ["unqualified-search-registries = []"]

  writeText (containersConfDir </> "containers.conf") $
    T.unlines
      [ "[engine]"
      , -- This is either systemd (call systemd user daemon via d-bus) or
        -- cgroupfs (directly write to /sys/fs/cgroup). The latter has fewer
        -- things to go wrong: the systemd user manager is not necessarily
        -- running for a CI runner for example.
        "cgroup_manager = \"cgroupfs\""
      , -- Don't log to journald (what would otherwise be the default), since we
        -- would like to keep the test environments self-contained.
        "events_logger = \"file\""
      ]

  pure layout
  where
    writeText path = LBS.writeFile path . LBS.fromStrict . TE.encodeUtf8

-- | Best-effort cleanup of any podman state inside the sandbox.
--
-- 'withSystemTempDirectory' deletes the tree on exit, but podman processes can
-- hold locks open. @podman system reset --force@ unwinds containers/images
-- cleanly. Failures are logged and swallowed — the tempdir removal is the
-- real backstop.
resetSandbox ::
  (HasProcessContext env, HasLogFunc env) =>
  PodmanSandbox ->
  RIO env ()
resetSandbox sandbox = do
  result <- try $ podmanProc sandbox ["system", "reset", "--force"] runProcess_
  case result of
    Right () -> pure ()
    Left (e :: SomeException) ->
      logWarn $ "podman system reset failed (ignored): " <> displayShow e
