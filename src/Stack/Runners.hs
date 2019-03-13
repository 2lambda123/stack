{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Utilities for running stack commands.
module Stack.Runners
    ( withGlobalConfigAndLock
    , withConfigAndLock
    , withBuildConfigAndLock
    , withDefaultBuildConfigAndLock
    , withCleanConfig
    , withBuildConfig
    , withDefaultBuildConfig
    , withBuildConfigExt
    , withBuildConfigDot
    , loadConfigWithOpts
    , loadCompilerVersion
    , withUserFileLock
    , munlockFile
    , withRunnerGlobal
    ) where

import           Stack.Prelude
import           Path
import           Path.IO
import           Stack.Build.Target(NeedTargets(..))
import           Stack.Config
import           Stack.Constants
import           Stack.DefaultColorWhen (defaultColorWhen)
import qualified Stack.Docker as Docker
import qualified Stack.Nix as Nix
import           Stack.Setup
import           Stack.Types.Config
import           Stack.Types.Runner
import           System.Environment (getEnvironment)
import           System.IO
import           System.FileLock
import           Stack.Dot

-- FIXME it seems wrong that we call loadBuildConfig multiple times
loadCompilerVersion :: GlobalOpts
                    -> Config
                    -> IO WantedCompiler
loadCompilerVersion go config =
    view wantedCompilerVersionL <$> runRIO config (loadBuildConfig (globalCompiler go))

-- | Enforce mutual exclusion of every action running via this
-- function, on this path, on this users account.
--
-- A lock file is created inside the given directory.  Currently,
-- stack uses locks per-snapshot.  In the future, stack may refine
-- this to an even more fine-grain locking approach.
--
withUserFileLock :: MonadUnliftIO m
                 => GlobalOpts
                 -> Path Abs Dir
                 -> (Maybe FileLock -> m a)
                 -> m a
withUserFileLock go@GlobalOpts{} dir act = do
    env <- liftIO getEnvironment
    let toLock = lookup "STACK_LOCK" env == Just "true"
    if toLock
        then do
            let lockfile = relFileLockfile
            let pth = dir </> lockfile
            ensureDir dir
            -- Just in case of asynchronous exceptions, we need to be careful
            -- when using tryLockFile here:
            bracket (liftIO $ tryLockFile (toFilePath pth) Exclusive)
                    (maybe (return ()) (liftIO . unlockFile))
                    (\fstTry ->
                        case fstTry of
                          Just lk -> finally (act $ Just lk) (liftIO $ unlockFile lk)
                          Nothing ->
                            do let chatter = globalLogLevel go /= LevelOther "silent"
                               when chatter $
                                 liftIO $ hPutStrLn stderr $ "Failed to grab lock ("++show pth++
                                                     "); other stack instance running.  Waiting..."
                               bracket (liftIO $ lockFile (toFilePath pth) Exclusive)
                                       (liftIO . unlockFile)
                                       (\lk -> do
                                            when chatter $
                                              liftIO $ hPutStrLn stderr "Lock acquired, proceeding."
                                            act $ Just lk))
        else act Nothing

withConfigAndLock
    :: GlobalOpts
    -> RIO Config ()
    -> IO ()
withConfigAndLock go@GlobalOpts{..} inner = loadConfigWithOpts go $ \config -> do
    withUserFileLock go (view stackRootL config) $ \lk ->
        runRIO config $
            Docker.reexecWithOptionalContainer
                (configProjectRoot config)
                Nothing
                (runRIO config inner)
                Nothing
                (Just $ munlockFile lk)

-- | Loads global config, ignoring any configuration which would be
-- loaded due to $PWD.
withGlobalConfigAndLock
    :: GlobalOpts
    -> RIO Config ()
    -> IO ()
withGlobalConfigAndLock go@GlobalOpts{..} inner =
    withRunnerGlobal go $ \runner ->
    runRIO runner $ loadConfigMaybeProject
      globalConfigMonoid
      globalResolver
      PCNoProject $ \lc ->
        withUserFileLock go (view stackRootL lc) $ \_lk ->
          runRIO lc inner

-- For now the non-locking version just unlocks immediately.
-- That is, there's still a serialization point.
withDefaultBuildConfig
    :: GlobalOpts
    -> RIO EnvConfig ()
    -> IO ()
withDefaultBuildConfig go inner =
    withBuildConfigAndLock go AllowNoTargets defaultBuildOptsCLI (\lk -> do munlockFile lk
                                                                            inner)

withBuildConfig
    :: GlobalOpts
    -> NeedTargets
    -> BuildOptsCLI
    -> RIO EnvConfig ()
    -> IO ()
withBuildConfig go needTargets boptsCLI inner =
    withBuildConfigAndLock go needTargets boptsCLI (\lk -> do munlockFile lk
                                                              inner)

withDefaultBuildConfigAndLock
    :: GlobalOpts
    -> (Maybe FileLock -> RIO EnvConfig ())
    -> IO ()
withDefaultBuildConfigAndLock go inner =
    withBuildConfigExt go AllowNoTargets defaultBuildOptsCLI Nothing inner Nothing

withBuildConfigAndLock
    :: GlobalOpts
    -> NeedTargets
    -> BuildOptsCLI
    -> (Maybe FileLock -> RIO EnvConfig ())
    -> IO ()
withBuildConfigAndLock go needTargets boptsCLI inner =
    withBuildConfigExt go needTargets boptsCLI Nothing inner Nothing

-- | A runner specially built for the "stack clean" use case. For some
-- reason (hysterical raisins?), all of the functions in this module
-- which say BuildConfig actually work on an EnvConfig, while the
-- clean command legitimately only needs a BuildConfig. At some point
-- in the future, we could consider renaming everything for more
-- consistency.
--
-- /NOTE/ This command always runs outside of the Docker environment,
-- since it does not need to run any commands to get information on
-- the project. This is a change as of #4480. For previous behavior,
-- see issue #2010.
withCleanConfig :: GlobalOpts -> RIO BuildConfig () -> IO ()
withCleanConfig go inner =
  loadConfigWithOpts go $ \config ->
  withUserFileLock go (view stackRootL config) $ \_lk0 -> do
    bconfig <- runRIO config $ loadBuildConfig $ globalCompiler go
    runRIO bconfig inner

withBuildConfigExt
    :: GlobalOpts
    -> NeedTargets
    -> BuildOptsCLI
    -> Maybe (RIO Config ())
    -- ^ Action to perform before the build.  This will be run on the host
    -- OS even if Docker is enabled for builds.  The build config is not
    -- available in this action, since that would require build tools to be
    -- installed on the host OS.
    -> (Maybe FileLock -> RIO EnvConfig ())
    -- ^ Action that uses the build config.  If Docker is enabled for builds,
    -- this will be run in a Docker container.
    -> Maybe (RIO Config ())
    -- ^ Action to perform after the build.  This will be run on the host
    -- OS even if Docker is enabled for builds.  The build config is not
    -- available in this action, since that would require build tools to be
    -- installed on the host OS.
    -> IO ()
withBuildConfigExt go@GlobalOpts{..} needTargets boptsCLI mbefore inner mafter = loadConfigWithOpts go $ \config -> do
    withUserFileLock go (view stackRootL config) $ \lk0 -> do
      -- A local bit of state for communication between callbacks:
      curLk <- newIORef lk0
      let inner' lk =
            -- Locking policy:  This is only used for build commands, which
            -- only need to lock the snapshot, not the global lock.  We
            -- trade in the lock here.
            do dir <- installationRootDeps
               -- Hand-over-hand locking:
               withUserFileLock go dir $ \lk2 -> do
                 liftIO $ writeIORef curLk lk2
                 liftIO $ munlockFile lk
                 logDebug "Starting to execute command inside EnvConfig"
                 inner lk2

      let inner'' lk = do
              bconfig <- runRIO config $ loadBuildConfig globalCompiler
              envConfig <- runRIO bconfig (setupEnv needTargets boptsCLI Nothing)
              runRIO envConfig (inner' lk)

      let getCompilerVersion = loadCompilerVersion go config
      runRIO config $
        Docker.reexecWithOptionalContainer
          (configProjectRoot config)
          mbefore
          (runRIO config $
              Nix.reexecWithOptionalShell (configProjectRoot config) getCompilerVersion (inner'' lk0))
          mafter
          (Just $ liftIO $
                do lk' <- readIORef curLk
                   munlockFile lk')

-- | Load the configuration. Convenience function used
-- throughout this module.
loadConfigWithOpts
  :: GlobalOpts
  -> (Config -> IO a)
  -> IO a
loadConfigWithOpts go@GlobalOpts{..} inner = withRunnerGlobal go $ \runner -> do
    mstackYaml <- forM globalStackYaml resolveFile'
    runRIO runner $
      loadConfig globalConfigMonoid globalResolver mstackYaml $ \config -> do
        -- If we have been relaunched in a Docker container, perform in-container initialization
        -- (switch UID, etc.).  We do this after first loading the configuration since it must
        -- happen ASAP but needs a configuration.
        forM_ globalDockerEntrypoint $ Docker.entrypoint config
        liftIO $ inner config

withRunnerGlobal :: GlobalOpts -> (Runner -> IO a) -> IO a
withRunnerGlobal GlobalOpts{..} inner = do
    defColorWhen <- defaultColorWhen
    let globalColorWhen =
            fromFirst defColorWhen (configMonoidColorWhen globalConfigMonoid)
    withRunner
        globalLogLevel
        globalTimeInLog
        globalTerminal
        globalColorWhen
        globalStylesUpdate
        globalTermWidth
        (isJust globalReExecVersion)
        inner

-- | Unlock a lock file, if the value is Just
munlockFile :: MonadIO m => Maybe FileLock -> m ()
munlockFile Nothing = return ()
munlockFile (Just lk) = liftIO $ unlockFile lk

-- Plumbing for --test and --bench flags
withBuildConfigDot
    :: DotOpts
    -> GlobalOpts
    -> RIO EnvConfig ()
    -> IO ()
withBuildConfigDot opts go f = withBuildConfig go' NeedTargets boptsCLI f
  where
    boptsCLI = defaultBuildOptsCLI
        { boptsCLITargets = dotTargets opts
        , boptsCLIFlags = dotFlags opts
        }
    go' =
        (if dotTestTargets opts then set (globalOptsBuildOptsMonoidL.buildOptsMonoidTestsL) (Just True) else id) $
        (if dotBenchTargets opts then set (globalOptsBuildOptsMonoidL.buildOptsMonoidBenchmarksL) (Just True) else id)
        go
