{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
module Replica.Run.Types where

import qualified Chronos                        as Ch
import           Control.Exception              (Exception)
import           Data.Aeson                     ((.:), (.=))
import qualified Data.Aeson                     as A
import qualified Data.ByteString                as B
import qualified Data.Text                      as T
import qualified Replica.VDOM                   as V

data Event = Event
  { evtType        :: T.Text
  , evtEvent       :: A.Value
  , evtPath        :: [Int]
  , evtClientFrame :: Int
  } deriving Show

instance A.FromJSON Event where
  parseJSON (A.Object o) = Event
    <$> o .: "eventType"
    <*> o .: "event"
    <*> o .: "path"
    <*> o .: "clientFrame"
  parseJSON _ = fail "Expected object"

data Update
  = ReplaceDOM V.HTML
  | UpdateDOM Int (Maybe Int) [V.Diff]

instance A.ToJSON Update where
  toJSON (ReplaceDOM dom) = A.object
    [ "type" .= V.t "replace"
    , "dom"  .= dom
    ]
  toJSON (UpdateDOM serverFrame clientFrame ddiff) = A.object
    [ "type" .= V.t "update"
    , "serverFrame" .= serverFrame
    , "clientFrame" .= clientFrame
    , "diff" .= ddiff
    ]


-- data AppConfig = AppConfig
--   { acfgTitle               :: T.Text
--   , acfgHeader              :: V.HTML
--   , acfgWSConnectionOptions :: ConnectionOptions
--   , acfgMiddleware          :: Middleware
--   }

-- data ReplicaAppConfig = forall st res. ReplicaAppConfig
--   { rcfgLogAction                :: Co.LogAction IO ReplicaLog
--   , rcfgWSInitialConnectLimit    :: Ch.Timespan      -- ^ Time limit for first connect
--   , rcfgWSReconnectionSpanLimit  :: Ch.Timespan      -- ^ limit for re-connecting span
--   , rcfgResourceAquire           :: IO res
--   , rcfgResourceRelease          :: res -> IO ()
--   , rcfgInitial                  :: res -> st
--   , rcfgStep                     :: (st -> IO (Maybe (V.HTML, st, Event -> Maybe (IO ()))))
--   }
--
-- data ReplicaApp = ReplicaApp
--   { rappConfig   :: ReplicaAppConfig
--   , rappSesMap   :: TVar (M.Map SessionID (Session, TVar SessionManageState))
--   , rappOrphans0 :: TVar (PSQ.OrdPSQ SessionID Ch.Time Session)   -- ^ 初期接続待ち
--   , rappOrphans  :: TVar (PSQ.OrdPSQ SessionID Ch.Time Session)   -- ^ 再接続待ち
--   }

-- data SessionManageState
--   = CMSOrphan
--   | CMSAttached
--   deriving (Eq, Show)

-- | Error/Exception

data SessionAttachingError
  = SessionDoesntExist
  | SessionAlreadyAttached
  deriving (Eq, Show)

instance Exception SessionAttachingError

data SessionEventError
  = IllformedData
  | InvalidEvent
  deriving Show

instance Exception SessionEventError
