{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Wai.Handler.Replica where

import           Control.Concurrent             (forkIO, killThread)
import           Control.Concurrent.STM         (TVar, atomically, newTVarIO, readTVar, writeTVar, retry)
import           Control.Monad                  (join, forever)
import           Control.Exception              (onException)

import           Data.Aeson                     ((.:), (.=))
import qualified Data.Aeson                     as A

import qualified Data.ByteString                as B
import qualified Data.ByteString.Lazy           as BL
import qualified Data.Text                      as T
import           Network.HTTP.Types             (status200)

import           Network.WebSockets             (ServerApp)
import           Network.WebSockets.Connection  (ConnectionOptions, Connection, acceptRequest, forkPingThread, receiveData, sendTextData, sendClose, sendCloseCode)
import           Network.Wai                    (Application, responseLBS)
import           Network.Wai.Handler.WebSockets (websocketsOr)

import qualified Replica.VDOM                   as V

import           Debug.Trace                    (traceIO)

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
  | UpdateDOM Int [V.Diff]

instance A.ToJSON Update where
  toJSON (ReplaceDOM dom) = A.object
    [ "type" .= V.t "replace"
    , "dom"  .= dom
    ]
  toJSON (UpdateDOM serverFrame ddiff) = A.object
    [ "type" .= V.t "update"
    , "serverFrame" .= serverFrame
    , "diff" .= ddiff
    ]

app :: forall st.
     B.ByteString
  -> V.HTML
  -> ConnectionOptions
  -> st
  -> (st -> IO (Maybe (V.HTML, st, Event -> IO ())))
  -> Application
app title header options initial step
  = websocketsOr options (websocketApp initial step) backupApp
  where
    indexBS = BL.fromStrict $ V.index title header

    backupApp :: Application
    backupApp _ respond = respond $ responseLBS status200 [("content-type", "text/html")] indexBS

websocketApp :: forall st.
     st
  -> (st -> IO (Maybe (V.HTML, st, Event -> IO ())))
  -> ServerApp
websocketApp initial step pendingConn = do
  conn <- acceptRequest pendingConn
  chan <- newTVarIO Nothing

  forkPingThread conn 30

  tid <- forkIO $ forever $ do
    msg  <- receiveData conn
    case A.decode msg of
      Just msg' -> do
        join $ atomically $ do
          fire <- readTVar chan
          case fire of
            Just fire' -> do
              writeTVar chan Nothing
              pure (fire' msg')
            Nothing -> retry
      Nothing -> traceIO $ "Couldn't decode event: " <> show msg

  go conn chan Nothing initial 0
    `onException` sendCloseCode conn closeCodeInternalError ("internal error" :: T.Text)
  sendClose conn ("done" :: T.Text)

  killThread tid

  where
    closeCodeInternalError = 1011

    go :: Connection -> TVar (Maybe (Event -> IO ())) -> Maybe V.HTML -> st -> Int -> IO ()
    go conn chan oldDom st serverFrame = do
      r <- step st
      case r of
        Nothing -> pure ()
        Just (newDom, next, fire) -> do
          case oldDom of
            Nothing      -> sendTextData conn $ A.encode $ ReplaceDOM newDom
            Just oldDom' -> sendTextData conn $ A.encode $ UpdateDOM serverFrame (V.diff oldDom' newDom)

          atomically $ writeTVar chan (Just fire)

          go conn chan (Just newDom) next (serverFrame + 1)
