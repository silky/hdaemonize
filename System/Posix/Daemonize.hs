{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
module System.Posix.Daemonize (
  -- * Simple daemonization
  daemonize,
  -- * Building system services
  serviced, CreateDaemon(..), simpleDaemon,
  -- * Intradaemon utilities
  fatalError, exitCleanly
  -- * An example
  --
  -- | Here is an example of a full program which writes a message to
  -- syslog once a second proclaiming its continued existance, and
  -- which installs its own SIGHUP handler.  Note that you won't
  -- actually see the message once a second in the log on most
  -- systems.  @syslogd@ detects repeated messages and prints the
  -- first one, then delays for the rest and eventually writes a line
  -- about how many times it has seen it.
  --
  -- > {-# LANGUAGE OverloadedStrings #-}
  -- > module Main where
  -- >
  -- > import System.Posix.Daemonize (CreateDaemon(..), serviced, simpleDaemon)
  -- > import System.Posix.Signals (installHandler, Handler(Catch), sigHUP, fullSignalSet)
  -- > import System.Posix.Syslog (syslogUnsafe, Facility(DAEMON), Priority(Notice))
  -- > import Control.Concurrent (threadDelay)
  -- > import Control.Monad (forever)
  -- >
  -- > main :: IO ()
  -- > main = serviced stillAlive
  -- >
  -- > stillAlive :: CreateDaemon ()
  -- > stillAlive = simpleDaemon { program = stillAliveMain }
  -- >
  -- > stillAliveMain :: () -> IO ()
  -- > stillAliveMain _ = do
  -- >   installHandler sigHUP (Catch taunt) (Just fullSignalSet)
  -- >   forever $ do threadDelay (10^6)
  -- >                syslog DAEMON Notice "I'm still alive!"
  -- >
  -- > taunt :: IO ()
  -- > taunt = syslogUnsafe DAEMON Notice "I sneeze in your general direction, you and your SIGHUP."

  ) where

{- originally based on code from
   http://sneakymustard.com/2008/12/11/haskell-daemons -}


import Control.Monad (when)
import Control.Monad.Trans
import Control.Exception.Extensible
import qualified Control.Monad as M (forever)

#if MIN_VERSION_base(4,6,0)
import Prelude
#else
import Prelude hiding (catch)
#endif

#if !(MIN_VERSION_base(4,8,0))
import Control.Applicative ((<$), (<$>))
#endif

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteString
import Data.Maybe (isNothing, fromMaybe, fromJust)
import System.Environment
import System.Exit
import System.Posix
import System.Posix.Syslog (withSyslog,SyslogConfig(..),Option(..),Priority(..),PriorityMask(..),Facility(..),syslogUnsafe)
import System.FilePath.Posix (joinPath)

syslog :: Priority -> ByteString -> IO ()
syslog = syslogUnsafe DAEMON

-- | Turning a process into a daemon involves a fixed set of
-- operations on unix systems, described in section 13.3 of Stevens
-- and Rago, "Advanced Programming in the Unix Environment."  Since
-- they are fixed, they can be written as a single function,
-- 'daemonize' taking an 'IO' action which represents the daemon's
-- actual activity.
--
-- Briefly, 'daemonize' sets the file creation mask to 0, forks twice,
-- changed the working directory to @/@, closes stdin, stdout, and
-- stderr, blocks 'sigHUP', and runs its argument.  Strictly, it
-- should close all open file descriptors, but this is not possible in
-- a sensible way in Haskell.
--
-- The most trivial daemon would be
--
-- > daemonize (forever $ return ())
--
-- which does nothing until killed.

daemonize :: IO () -> IO ()
daemonize program = do
        setFileCreationMask 0
        forkProcess p
        exitImmediately ExitSuccess
    where
      p  = do createSession
              forkProcess p'
              exitImmediately ExitSuccess
      p' = do changeWorkingDirectory "/"
              closeFileDescriptors
              blockSignal sigHUP
              program




-- | 'serviced' turns a program into a UNIX daemon (system service)
--   ready to be deployed to /etc/rc.d or similar startup folder.  It
--   is meant to be used in the @main@ function of a program, such as
--
-- > serviced simpleDaemon
--
--   The resulting program takes one of three arguments: @start@,
--   @stop@, and @restart@.  All control the status of a daemon by
--   looking for a file containing a text string holding the PID of
--   any running instance.  Conventionally, this file is in
--   @/var/run/$name.pid@, where $name is the executable's name.  For
--   obvious reasons, this file is known as a PID file.
--
--   @start@ makes the program write a PID file.  If the file already
--   exists, it refuses to start, guaranteeing there is only one
--   instance of the daemon at any time.
--
--   @stop@ read the PID file, and terminates the process whose pid is
--   written therein.  First it does a soft kill, SIGTERM, giving the
--   daemon a chance to shut down cleanly, then three seconds later a
--   hard kill which the daemon cannot catch or escape.
--
--   @restart@ is simple @stop@ followed by @start@.
--
--   'serviced' also tries to drop privileges.  If you don't specify a
--   user the daemon should run as, it will try to switch to a user
--   with the same name as the daemon, and otherwise to user @daemon@.
--   It goes through the same sequence for group.  Just to complicate
--   matters, the name of the daemon is by default the name of the
--   executable file, but can again be set to something else in the
--   'CreateDaemon' record.
--
--   Finally, exceptions in the program are caught, logged to syslog,
--   and the program restarted.

serviced :: CreateDaemon a -> IO ()
serviced daemon = do
        systemName <- getProgName
        let daemon' = daemon { name = if isNothing (name daemon)
                                        then Just systemName else name daemon }
        args <- getArgs
        process daemon' args
    where
      program' daemon = withSyslog (SyslogConfig (ByteString.pack $ fromJust $ name daemon) (syslogOptions daemon) DAEMON NoMask) $ \_ ->
                      do let log = syslog Notice
                         log "starting"
                         pidWrite daemon
                         privVal <- privilegedAction daemon
                         dropPrivileges daemon
                         forever $ program daemon privVal

      process daemon ["start"] = pidExists daemon >>= f where
          f True  = do error "PID file exists. Process already running?"
                       exitImmediately (ExitFailure 1)
          f False = daemonize (program' daemon)

      process daemon ["stop"]  =
          do pid <- pidRead daemon
             case pid of
               Nothing  -> pass
               Just pid ->
                   whenM (pidLive pid)
                            (do signalProcess sigTERM pid
                                usleep (10^3)
                                wait (killWait daemon) pid)
                   `finally`
                   removeLink (pidFile daemon)

      process daemon ["restart"] = do process daemon ["stop"]
                                      process daemon ["start"]

      process daemon ["status"] = pidExists daemon >>= f where
        f True =
          do pid <- pidRead daemon
             case pid of
               Nothing -> putStrLn $ fromJust (name daemon) ++ " is not running."
               Just pid ->
                 do res <- pidLive pid
                    if res then
                              putStrLn $ fromJust (name daemon) ++ " is running."
                         else putStrLn $ fromJust (name daemon) ++ " is not running, but pidfile is remaining."
        f False = putStrLn $ fromJust (name daemon) ++ " is not running."

      process _      _ =
        getProgName >>= \pname -> putStrLn $ "usage: " ++ pname ++ " {start|stop|status|restart}"

      -- Wait 'secs' seconds for the process to exit, checking
      -- for liveness once a second.  If still alive send sigKILL.
      wait :: Maybe Int -> CPid -> IO ()
      wait secs pid =
          whenM (pidLive pid) $
               if maybe True (> 0) secs
               then do usleep (10^6)
                       wait (fmap (\x->x-1) secs) pid
               else signalProcess sigKILL pid

-- | A monadic-conditional version of the "when" guard (copied from shelly.)
whenM :: Monad m => m Bool -> m () -> m ()
whenM c a = c >>= \res -> when res a

-- | The details of any given daemon are fixed by the 'CreateDaemon'
-- record passed to 'serviced'.  You can also take a predefined form
-- of 'CreateDaemon', such as 'simpleDaemon' below, and set what
-- options you want, rather than defining the whole record yourself.
data CreateDaemon a = CreateDaemon {
  privilegedAction :: IO a, -- ^ An action to be run as root, before
                            -- permissions are dropped, e.g., binding
                            -- a trusted port.
  program :: a -> IO (), -- ^ The actual guts of the daemon, more or less
                         -- the @main@ function.  Its argument is the result
                         -- of running 'privilegedAction' before dropping
                         -- privileges.
  name :: Maybe String, -- ^ The name of the daemon, which is used as
                        -- the name for the PID file, as the name that
                        -- appears in the system logs, and as the user
                        -- and group the daemon tries to run as if
                        -- none are explicitly specified.  In general,
                        -- this should be 'Nothing', in which case the
                        -- system defaults to the name of the
                        -- executable file containing the daemon.
  user :: Maybe String, -- ^ Most daemons are initially run as root,
                        -- and try to change to another user so they
                        -- have fewer privileges and represent less of
                        -- a security threat.  This field specifies
                        -- which user it should try to run as.  If it
                        -- is 'Nothing', or if the user does not exist
                        -- on the system, it next tries to become a
                        -- user with the same name as the daemon, and
                        -- if that fails, the user @daemon@.
  group :: Maybe String, -- ^ 'group' is the group the daemon should
                         -- try to run as, and works the same way as
                         -- the user field.
  syslogOptions :: [Option], -- ^ The options the daemon should set on
                             -- syslog.  You can safely leave this as @[]@.
  pidfileDirectory :: Maybe FilePath, -- ^ The directory where the
                                      -- daemon should write and look
                                      -- for the PID file.  'Nothing'
                                      -- means @/var/run@.  Unless you
                                      -- have a good reason to do
                                      -- otherwise, leave this as
                                      -- 'Nothing'.
  killWait :: Maybe Int -- ^ How many seconds to wait between sending
                        -- sigTERM and sending sigKILL.  If Nothing
                        -- wait forever.  Default 4.
}

-- | The simplest possible instance of 'CreateDaemon' is
--
-- > CreateDaemon {
-- >  privilegedAction = return ()
-- >  program = const $ forever $ return ()
-- >  name = Nothing,
-- >  user = Nothing,
-- >  group = Nothing,
-- >  syslogOptions = [],
-- >  pidfileDirectory = Nothing,
-- > }
--
-- which does nothing forever with all default settings.  We give it a
-- name, 'simpleDaemon', since you may want to use it as a template
-- and modify only the fields that you need.

simpleDaemon :: CreateDaemon ()
simpleDaemon = CreateDaemon {
  name = Nothing,
  user = Nothing,
  group = Nothing,
  syslogOptions = [],
  pidfileDirectory = Nothing,
  program = const $ M.forever $ return (),
  privilegedAction = return (),
  killWait = Just 4
}




{- implementation -}

forever :: IO () -> IO ()
forever program =
    program `catch` restart where
        restart :: SomeException -> IO ()
        restart e =
            do syslog Error $ ByteString.pack ("unexpected exception: " ++ show e)
               syslog Error "restarting in 5 seconds"
               usleep (5 * 10^6)
               forever program

closeFileDescriptors :: IO ()
closeFileDescriptors =
    do null <- openFd "/dev/null" ReadWrite Nothing defaultFileFlags
       let sendTo fd' fd = closeFd fd >> dupTo fd' fd
       mapM_ (sendTo null) [stdInput, stdOutput, stdError]

blockSignal :: Signal -> IO ()
blockSignal sig = installHandler sig Ignore Nothing >> pass

getGroupID :: String -> IO (Maybe GroupID)
getGroupID group =
        f <$> try (fmap groupID (getGroupEntryForName group))
    where
        f :: Either IOException GroupID -> Maybe GroupID
        f (Left _)    = Nothing
        f (Right gid) = Just gid

getUserID :: String -> IO (Maybe UserID)
getUserID user =
        f <$> try (fmap userID (getUserEntryForName user))
    where
        f :: Either IOException UserID -> Maybe UserID
        f (Left _)    = Nothing
        f (Right uid) = Just uid

dropPrivileges :: CreateDaemon a -> IO ()
dropPrivileges daemon =
    do Just ud <- getUserID "daemon"
       Just gd <- getGroupID "daemon"
       let targetUser = fromMaybe (fromJust $ name daemon) (user daemon)
           targetGroup = fromMaybe (fromJust $ name daemon) (group daemon)
       u <- fromMaybe ud <$> getUserID targetUser
       g <- fromMaybe gd <$> getGroupID targetGroup
       setGroupID g
       setUserID u

pidFile:: CreateDaemon a -> String
pidFile daemon = joinPath [dir, fromJust (name daemon) ++ ".pid"]
  where dir = fromMaybe "/var/run" (pidfileDirectory daemon)

pidExists :: CreateDaemon a -> IO Bool
pidExists daemon = fileExist (pidFile daemon)

pidRead :: CreateDaemon a -> IO (Maybe CPid)
pidRead daemon = pidExists daemon >>= choose where
    choose True  = return . read <$> readFile (pidFile daemon)
    choose False = return Nothing

pidWrite :: CreateDaemon a -> IO ()
pidWrite daemon =
    getProcessID >>= \pid ->
    writeFile (pidFile daemon) (show pid)

pidLive :: CPid -> IO Bool
pidLive pid =
    (getProcessPriority pid >> return True) `catch` f where
        f :: IOException -> IO Bool
        f _ = return False

pass :: IO ()
pass = return ()

-- | When you encounter an error where the only sane way to handle it
-- is to write an error to the log and die messily, use fatalError.
-- This is a good candidate for things like not being able to find
-- configuration files on startup.
fatalError :: MonadIO m => String -> m a
fatalError msg = liftIO $ do
  syslog Error $ ByteString.pack $ "Terminating from error: " ++ msg
  exitImmediately (ExitFailure 1)
  undefined -- You will never reach this; it's there to make the type checker happy

-- | Use this function when the daemon should terminate normally.  It
-- logs a message, and exits with status 0.
exitCleanly :: MonadIO m => m a
exitCleanly = liftIO $ do
  syslog Notice "Exiting."
  exitImmediately ExitSuccess
  undefined -- You will never reach this; it's there to make the type checker happy
