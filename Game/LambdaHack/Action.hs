{-# OPTIONS -fno-warn-orphans #-}
{-# LANGUAGE OverloadedStrings, RankNTypes #-}
-- | Game action monads and basic building blocks for player and monster
-- actions. Has no access to the the main action type @Action@.
-- Does not export the @liftIO@ operation nor a few other implementation
-- details.
module Game.LambdaHack.Action
  ( -- * Action monads
    MonadActionAbort(..)
  , MonadActionRO(..)
  , MonadAction(..)
  , ConnClient(..)
    -- * Various ways to abort action
  , abort, abortIfWith, neverMind
    -- * Abort exception handlers
  , tryRepeatedlyWith, tryIgnore
    -- * Assorted primitives
  , rndToAction
  , debug
  ) where

import Control.Concurrent.Chan
import qualified Control.Monad.State as St
import Control.Monad.Writer.Strict (WriterT (WriterT), lift, runWriterT)
import Data.Dynamic
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
-- import System.IO (hPutStrLn, stderr) -- just for debugging

import Game.LambdaHack.CmdCli
import Game.LambdaHack.Msg
import Game.LambdaHack.Random
import Game.LambdaHack.State
import Game.LambdaHack.Utils.Assert

-- | Connection channels between server and a single client.
data ConnClient = ConnClient
  { toClient   :: Chan CmdCli
  , toServer   :: Chan Dynamic
  }

instance Show ConnClient where
  show _ = "client channels"

-- | The bottom of the action monads class semilattice.
class (Monad m, Functor m, Show (m ())) => MonadActionAbort m where
  -- Set the current exception handler. First argument is the handler,
  -- second is the computation the handler scopes over.
  tryWith      :: (Msg -> m a) -> m a -> m a
  -- Abort with the given message.
  abortWith    :: Msg -> m a

instance (Monoid a, MonadActionAbort m) => MonadActionAbort (WriterT a m) where
  tryWith exc m =
    WriterT $ tryWith (\msg -> runWriterT (exc msg)) (runWriterT m)
  abortWith   = lift . abortWith

instance MonadActionAbort m => Show (WriterT a m b) where
  show _ = "an action"

class MonadActionAbort m => MonadActionRO m where
  getState    :: m State
  getsState   :: (State -> a) -> m a

instance (Monoid a, MonadActionRO m) => MonadActionRO (WriterT a m) where
  getState    = lift getState
  getsState   = lift . getsState

class MonadActionRO m => MonadAction m where
  modifyState :: (State -> State) -> m ()
  putState    :: State -> m ()

instance (Monoid a, MonadAction m) => MonadAction (WriterT a m) where
  modifyState = lift . modifyState
  putState    = lift . putState

-- | Reset the state and resume from the last backup point, i.e., invoke
-- the failure continuation.
abort :: MonadActionAbort m => m a
abort = abortWith ""

-- | Abort and print the given msg if the condition is true.
abortIfWith :: MonadActionAbort m => Bool -> Msg -> m a
abortIfWith True msg = abortWith msg
abortIfWith False _  = abortWith ""

-- | Abort and conditionally print the fixed message.
neverMind :: MonadActionAbort m => Bool -> m a
neverMind b = abortIfWith b "never mind"

-- | Take a handler and a computation. If the computation fails, the
-- handler is invoked and then the computation is retried.
tryRepeatedlyWith :: MonadActionAbort m => (Msg -> m ()) -> m () -> m ()
tryRepeatedlyWith exc m =
  tryWith (\msg -> exc msg >> tryRepeatedlyWith exc m) m

-- | Try the given computation and silently catch failure.
tryIgnore :: MonadActionAbort m => m () -> m ()
tryIgnore =
  tryWith (\msg -> if T.null msg
                   then return ()
                   else assert `failure` msg <+> "in tryIgnore")

-- | Invoke pseudo-random computation with the generator kept in the state.
rndToAction :: MonadAction m => Rnd a -> m a
rndToAction r = do
  g <- getsState srandom
  let (a, ng) = St.runState r g
  modifyState $ updateRandom $ const ng
  return a

-- | Debugging.
debug :: MonadActionAbort m => Text -> m ()
debug _x = return () -- liftIO $ hPutStrLn stderr _x
