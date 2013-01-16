{-# OPTIONS -fno-warn-orphans #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances #-}
-- | Basic type classes for game actions.
-- This module should not be imported anywhere except in 'Action'
-- and 'TypeAction'.
module Game.LambdaHack.Server.Action.ActionClass where

import Control.Monad.Reader.Class
import Control.Monad.Writer.Strict (WriterT, lift)
import qualified Data.IntMap as IM
import Data.Monoid

import Game.LambdaHack.State
import Game.LambdaHack.Action

-- | Connection information for each client and an optional AI client
-- for the same faction, indexed by faction identifier.
type ConnDict = IM.IntMap ConnFaction

type ConnFaction = (ConnClient, Maybe ConnClient)

class (MonadReader Pers m, MonadActionRO m) => MonadServerRO m where
  getServer    :: m StateServer
  getsServer   :: (StateServer -> a) -> m a

instance (Monoid a, MonadServerRO m) => MonadServerRO (WriterT a m) where
  getServer    = lift getServer
  getsServer   = lift . getsServer

class (MonadAction m, MonadServerRO m) => MonadServer m where
  modifyServer :: (StateServer -> StateServer) -> m ()
  putServer    :: StateServer -> m ()
  -- We do not provide a MonadIO instance, so that outside of Action/
  -- nobody can subvert the action monads by invoking arbitrary IO.
  liftIO       :: IO a -> m a

instance (Monoid a, MonadServer m) => MonadServer (WriterT a m) where
  modifyServer = lift . modifyServer
  putServer    = lift . putServer
  liftIO       = lift . liftIO

class MonadServer m => MonadServerChan m where
  getDict      :: m ConnDict
  getsDict     :: (ConnDict -> a) -> m a
  modifyDict   :: (ConnDict -> ConnDict) -> m ()
  putDict      :: ConnDict -> m ()

instance (Monoid a, MonadServerChan m) => MonadServerChan (WriterT a m) where
  getDict      = lift getDict
  getsDict     = lift . getsDict
  modifyDict   = lift . modifyDict
  putDict      = lift . putDict
