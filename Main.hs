-- | Minimal repro for `withCheckedProcessCleanup` and `sourceProcessWithStreams`
-- not killing the child process when an async exception (via `timeout`) arrives
-- before the process has fully started.
--
-- Run with:
--   cabal run repro
--
-- Note [withCheckedProcessCleanup-leak]:
--
-- The bug is in the `bracket` pattern used by `withCheckedProcessCleanup`:
--
-- > withCheckedProcessCleanup cp f = withRunInIO $ \run -> bracket
-- >     (streamingProcess cp)                                    -- acquire
-- >     (\(_, _, _, sph) -> closeStreamingProcessHandle sph)     -- release
-- >     $ \(x, y, z, sph) -> do
-- >         res <- run (f x y z) `onException` terminateStreamingProcess sph
-- >         ...
--
-- The release action only calls `closeStreamingProcessHandle` (closes the
-- handle) but does NOT call `terminateStreamingProcess` (sends SIGTERM).
-- The `terminateStreamingProcess` call is in the `onException` handler
-- inside the bracket body.
--
-- When an async exception (from `timeout`) arrives after `streamingProcess`
-- completes (process is spawned) but before `onException` is installed,
-- `bracket` runs the release action which just closes the handle, leaving
-- the child process running as an orphan.
--
-- Fix: the release action should also terminate the process, e.g.:
--
-- > (\(_, _, _, sph) -> terminateStreamingProcess sph
-- >                  >> closeStreamingProcessHandle sph)
module Main where

import Prelude
import System.Process (callProcess, readProcess, terminateProcess, CreateProcess)
import System.Timeout (timeout)
import System.Exit (exitFailure, ExitCode(..))
import System.IO.Error (ioeGetErrorType, isResourceVanishedErrorType)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (runConcurrently, Concurrently(..))
import Control.Exception (try, SomeException, bracket, onException, throwIO, finally, catch)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO, withUnliftIO, unliftIO)
import Data.ByteString (ByteString)
import Data.List (isInfixOf)
import Data.Void (Void)
import qualified Data.Conduit as C
import Data.Conduit (ConduitT, runConduit, (.|), catchC)
import qualified Data.Conduit.Process as C
import Data.Streaming.Process (streamingProcess, closeStreamingProcessHandle, waitForStreamingProcess, StreamingProcessHandle, InputSource, OutputSink, ProcessExitedUnsuccessfully(..))
import Data.Streaming.Process.Internal (StreamingProcessHandle(..))


-- | Timeout in microseconds.
newtype TimeoutUs = TimeoutUs Int
  deriving (Eq, Ord, Show)


-- In all tests we wait for 12345 seconds so that we can find it easily in `ps`
-- and if the process doesn't get killed, we will be able to see it for long.
-- Also 12345 seconds must be significantly greater than
-- `_RACE_SLEEP_US_IN_BRACKET_ACQUIRE` for the race to work.


-- | Check whether any @sleep 12345@ process is running, using @ps@.
-- Returns 'True' if at least one is found.
sleepIsRunning :: IO Bool
sleepIsRunning = do
  -- `ps aux` lists all processes; we grep for our unique sentinel duration.
  out <- readProcess "ps" ["aux"] ""
  -- Filter out the grep/ps process itself and our own Haskell process.
  let needle = "sleep 12345"
  let matching = filter (\l -> needle `isInfixOf` l && not ("grep" `isInfixOf` l)) (lines out)
  return (not (null matching))


-- | Kill any lingering @sleep 12345@ processes.
-- Calls 'error' if the process is still running after being killed.
killLeakedSleeps :: IO ()
killLeakedSleeps = do
  -- `pkill -f` sends SIGTERM to matching processes; ignore failure (no match).
  _ <- try (callProcess "pkill" ["-f", "sleep 12345"]) :: IO (Either SomeException ())
  threadDelay 200000 -- 200 ms for the process to die
  stillRunning <- sleepIsRunning
  when stillRunning $
    error "killLeakedSleeps: sleep 12345 is still running after pkill!"


-- | Run a single test case: apply `timeout` with the given microseconds to
-- the given action, then check whether the @sleep 12345@ process leaked.
-- Returns 'True' on success (no leak), 'False' on failure (leak detected).
runCase :: String -> TimeoutUs -> IO () -> IO Bool
runCase label (TimeoutUs us) action = do
  alreadyRunning <- sleepIsRunning
  when alreadyRunning $
    error $ "runCase " ++ show label ++ ": sleep 12345 is already running before the test!"
  putStrLn $ "\n--- " ++ label ++ " (timeout " ++ show us ++ " µs) ---"
  result <- timeout us action
  putStrLn $ "  timeout returned: " ++ maybe "Nothing" (const "Just ()") result

  -- Give the OS a moment to update the process table.
  threadDelay 100000 -- 100 ms

  leaked <- sleepIsRunning

  if leaked
    then do
      putStrLn "  FAIL: sleep 12345 is still running (leaked)!"
      killLeakedSleeps
      return False
    else do
      putStrLn "  OK: sleep 12345 is not running."
      return True


-- | The conduit-based action using `withCheckedProcessCleanup`.
-- See note [withCheckedProcessCleanup-leak].
conduitSleep :: IO ()
conduitSleep =
  C.withCheckedProcessCleanup (C.proc "sleep" ["12345"]) $
    \C.Inherited C.Inherited errorSource ->
      C.runConduit (errorSource C..| C.awaitForever (\line -> liftIO $ print line))


-- | Same as `conduitSleep` but using `sourceProcessWithStreams` instead.
-- `sourceProcessWithStreams` uses `onException terminateStreamingProcess`
-- with `finally` for cleanup, so it may behave differently.
conduitSleepStreams :: IO ()
conduitSleepStreams = do
  (_ec, _stdout, _stderr) <- C.sourceProcessWithStreams
    (C.proc "sleep" ["12345"])
    (return ())  -- stdin: nothing
    (C.awaitForever (\line -> liftIO $ print line))  -- stdout
    (C.awaitForever (\line -> liftIO $ print line))  -- stderr
  return ()

_RACE_SLEEP_US_IN_BRACKET_ACQUIRE :: Int
_RACE_SLEEP_US_IN_BRACKET_ACQUIRE = 500000

-- | Exact copy of `withCheckedProcessCleanup` from @conduit-extra-1.3.8@,
-- with an additional sleep in the right spot,
-- reproducing the buggy `bracket` release action.
-- See note [withCheckedProcessCleanup-leak].
withCheckedProcessCleanupBuggy
  :: ( InputSource stdin
     , OutputSink stderr
     , OutputSink stdout
     , MonadUnliftIO m
     )
  => CreateProcess
  -> (stdin -> stdout -> stderr -> m b)
  -> m b
withCheckedProcessCleanupBuggy cp f = withRunInIO $ \run -> bracket
  (streamingProcess cp)
  (\(_, _, _, sph) -> closeStreamingProcessHandle sph)
  $ \(x, y, z, sph) -> do
      threadDelay _RACE_SLEEP_US_IN_BRACKET_ACQUIRE
      res <- run (f x y z) `onException` terminateProcess' sph
      ec <- waitForStreamingProcess sph
      if ec == ExitSuccess
        then return res
        else throwIO $ ProcessExitedUnsuccessfully cp ec


-- | Fixed version of `withCheckedProcessCleanup`: the release action also
-- terminates the process, so an async exception between acquire and the
-- `onException` handler cannot leak the child.
-- See note [withCheckedProcessCleanup-leak].
withCheckedProcessCleanupFixed
  :: ( InputSource stdin
     , OutputSink stderr
     , OutputSink stdout
     , MonadUnliftIO m
     )
  => CreateProcess
  -> (stdin -> stdout -> stderr -> m b)
  -> m b
withCheckedProcessCleanupFixed cp f = withRunInIO $ \run -> bracket
  (streamingProcess cp)
  (\(_, _, _, sph) -> terminateProcess' sph >> closeStreamingProcessHandle sph)
  $ \(x, y, z, sph) -> do
      threadDelay _RACE_SLEEP_US_IN_BRACKET_ACQUIRE
      res <- run (f x y z)
      ec <- waitForStreamingProcess sph
      if ec == ExitSuccess
        then return res
        else throwIO $ ProcessExitedUnsuccessfully cp ec


-- | Exact copy of `sourceProcessWithStreams` from @conduit-extra-1.3.8@,
-- with an additional sleep in the right spot.
--
-- Note [sourceProcessWithStreams-leak]:
--
-- This function does NOT use `bracket`. It calls `streamingProcess` in a
-- plain `do` block, then applies `onException terminateStreamingProcess`
-- only to the `runConcurrently` call. An async exception arriving between
-- `streamingProcess` returning and `onException` being installed leaks the
-- child process. Unlike `withCheckedProcessCleanup`, there is no `bracket`
-- at all, so not even the handles get closed in that gap.
sourceProcessWithStreamsBuggy
  :: MonadUnliftIO m
  => CreateProcess
  -> ConduitT () ByteString m ()     -- ^ stdin
  -> ConduitT ByteString Void m a    -- ^ stdout
  -> ConduitT ByteString Void m b    -- ^ stderr
  -> m (ExitCode, a, b)
sourceProcessWithStreamsBuggy cp producerStdin consumerStdout consumerStderr =
  withUnliftIO $ \u -> do
    (  (sinkStdin, closeStdin)
     , (sourceStdout, closeStdout)
     , (sourceStderr, closeStderr)
     , sph) <- streamingProcess cp
    threadDelay _RACE_SLEEP_US_IN_BRACKET_ACQUIRE
    let safeSinkStdin = sinkStdin `catchC` ignoreStdinClosed
        safeCloseStdin = closeStdin `catch` ignoreStdinClosed
    (_, resStdout, resStderr) <-
      runConcurrently (
        (,,)
        <$> Concurrently ((unliftIO u $ runConduit $ producerStdin .| safeSinkStdin) `finally` safeCloseStdin)
        <*> Concurrently (unliftIO u $ runConduit $ sourceStdout .| consumerStdout)
        <*> Concurrently (unliftIO u $ runConduit $ sourceStderr .| consumerStderr))
      `finally` (closeStdout >> closeStderr)
      `onException` terminateProcess' sph
    ec <- waitForStreamingProcess sph
    return (ec, resStdout, resStderr)
  where
    ignoreStdinClosed :: (MonadIO m') => IOError -> m' ()
    ignoreStdinClosed e =
      if isResourceVanishedErrorType (ioeGetErrorType e)
        then pure ()
        else liftIO (throwIO e)


-- | Fixed version of `sourceProcessWithStreams`: wraps the entire body in
-- `bracket` so that the process gets terminated on any exception, including
-- async exceptions arriving before `onException` is installed.
-- See note [sourceProcessWithStreams-leak].
sourceProcessWithStreamsFixed
  :: MonadUnliftIO m
  => CreateProcess
  -> ConduitT () ByteString m ()     -- ^ stdin
  -> ConduitT ByteString Void m a    -- ^ stdout
  -> ConduitT ByteString Void m b    -- ^ stderr
  -> m (ExitCode, a, b)
sourceProcessWithStreamsFixed cp producerStdin consumerStdout consumerStderr =
  withUnliftIO $ \u -> bracket
    (streamingProcess cp)
    (\(_, _, _, sph) -> terminateProcess' sph >> closeStreamingProcessHandle sph)
    $ \((sinkStdin, closeStdin), (sourceStdout, closeStdout), (sourceStderr, closeStderr), sph) -> do
      threadDelay _RACE_SLEEP_US_IN_BRACKET_ACQUIRE
      let safeSinkStdin = sinkStdin `catchC` ignoreStdinClosed
          safeCloseStdin = closeStdin `catch` ignoreStdinClosed
      (_, resStdout, resStderr) <-
        runConcurrently (
          (,,)
          <$> Concurrently ((unliftIO u $ runConduit $ producerStdin .| safeSinkStdin) `finally` safeCloseStdin)
          <*> Concurrently (unliftIO u $ runConduit $ sourceStdout .| consumerStdout)
          <*> Concurrently (unliftIO u $ runConduit $ sourceStderr .| consumerStderr))
        `finally` (closeStdout >> closeStderr)
      ec <- waitForStreamingProcess sph
      return (ec, resStdout, resStderr)
  where
    ignoreStdinClosed :: (MonadIO m') => IOError -> m' ()
    ignoreStdinClosed e =
      if isResourceVanishedErrorType (ioeGetErrorType e)
        then pure ()
        else liftIO (throwIO e)


-- | Terminate the process via its `StreamingProcessHandle`.
-- This is equivalent to the unexported `terminateStreamingProcess` from
-- @conduit-extra@, which does @terminateProcess . streamingProcessHandleRaw@.
-- Neither `terminateStreamingProcess` nor `streamingProcessHandleRaw` are
-- exported, so we pattern-match on the `StreamingProcessHandle` constructor
-- from `Data.Streaming.Process.Internal` to extract the raw `ProcessHandle`.
terminateProcess' :: StreamingProcessHandle -> IO ()
terminateProcess' (StreamingProcessHandle ph _ _) = terminateProcess ph


main :: IO ()
main = do
  putStrLn "=== withCheckedProcessCleanup no-kill repro ==="
  putStrLn "See note [withCheckedProcessCleanup-leak]."
  putStrLn ""

  -- Case 1: `callProcess` with a very short timeout (1 µs).
  -- Expected: instakill, sleep does NOT leak.
  ok1 <- runCase "callProcess (control)" (TimeoutUs (_RACE_SLEEP_US_IN_BRACKET_ACQUIRE `div` 2)) $
    callProcess "sleep" ["12345"]

  -- Case 2: conduit `withCheckedProcessCleanup` with a generous timeout (2 s).
  -- Expected: killed after 2 s, sleep does NOT leak.
  ok2 <- runCase "withCheckedProcessCleanup (2 s timeout)" (TimeoutUs 2000000)
    conduitSleep

  -- Case 3: conduit `withCheckedProcessCleanup` with a very short timeout (1 µs).
  -- Expected: instakill, sleep does NOT leak.
  -- BUG: `timeout` returns `Nothing` immediately but the sleep process
  -- keeps running for the full 12345 seconds.
  ok3 <- runCase "withCheckedProcessCleanup (1 µs timeout) -- BUG (but may be flaky due to timing)" (TimeoutUs 1)
    conduitSleep

  -- Case 4: `sourceProcessWithStreams` with a very short timeout (1 µs).
  -- This uses a different cleanup pattern; does it also leak?
  ok4 <- runCase "sourceProcessWithStreams (1 µs timeout)" (TimeoutUs 1)
    conduitSleepStreams

  -- Case 5: Our copy of `withCheckedProcessCleanup` (buggy, same as upstream).
  ok5 <- runCase "withCheckedProcessCleanupBuggy (1 µs)" (TimeoutUs (_RACE_SLEEP_US_IN_BRACKET_ACQUIRE `div` 2)) $
    withCheckedProcessCleanupBuggy (C.proc "sleep" ["12345"]) $
      \C.Inherited C.Inherited errorSource ->
        C.runConduit (errorSource C..| C.awaitForever (\line -> liftIO $ print line))

  -- Case 6: Our fixed copy with terminate in the release action.
  ok6 <- runCase "withCheckedProcessCleanupFixed (1 µs)" (TimeoutUs (_RACE_SLEEP_US_IN_BRACKET_ACQUIRE `div` 2)) $
    withCheckedProcessCleanupFixed (C.proc "sleep" ["12345"]) $
      \C.Inherited C.Inherited errorSource ->
        C.runConduit (errorSource C..| C.awaitForever (\line -> liftIO $ print line))

  -- Case 7: Our copy of `sourceProcessWithStreams` (buggy, same as upstream).
  -- See note [sourceProcessWithStreams-leak].
  ok7 <- runCase "sourceProcessWithStreamsBuggy (1 µs)" (TimeoutUs (_RACE_SLEEP_US_IN_BRACKET_ACQUIRE `div` 2)) $ do
    _ <- sourceProcessWithStreamsBuggy
      (C.proc "sleep" ["12345"])
      (return ())
      (C.awaitForever (\line -> liftIO $ print line))
      (C.awaitForever (\line -> liftIO $ print line))
    return ()

  -- Case 8: Our fixed copy of `sourceProcessWithStreams` with `bracket`.
  ok8 <- runCase "sourceProcessWithStreamsFixed (1 µs)" (TimeoutUs (_RACE_SLEEP_US_IN_BRACKET_ACQUIRE `div` 2)) $ do
    _ <- sourceProcessWithStreamsFixed
      (C.proc "sleep" ["12345"])
      (return ())
      (C.awaitForever (\line -> liftIO $ print line))
      (C.awaitForever (\line -> liftIO $ print line))
    return ()

  putStrLn ""
  putStrLn "=== Summary ==="
  let results =
        [ ("callProcess (control)",                                                  ok1)
        , ("withCheckedProcessCleanup (2 s)",                                        ok2)
        , ("withCheckedProcessCleanup (1 µs) BUG (but may be flaky due to timing)",  ok3)
        , ("sourceProcessWithStreams (1 µs)",                                        ok4)
        , ("withCheckedProcessCleanupBuggy (1 µs)",                                  ok5)
        , ("withCheckedProcessCleanupFixed (1 µs)",                                  ok6)
        , ("sourceProcessWithStreamsBuggy (1 µs)",                                   ok7)
        , ("sourceProcessWithStreamsFixed (1 µs)",                                   ok8)
        ]
  mapM_ (\(name, ok) -> putStrLn $ "  " ++ (if ok then "OK  " else "FAIL") ++ "  " ++ name) results

  if all snd results
    then putStrLn "\nAll passed (bug not reproduced)."
    else do
      putStrLn "\nBug reproduced: some cases leaked the child process."
      exitFailure
