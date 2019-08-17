{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Replica
  ( Config(..)
  , app
  ) where

import qualified Colog.Core                     as Co
import qualified Chronos                        as Ch
import           Control.Concurrent.Async       (race)
import           Control.Concurrent.STM         (STM, atomically, check)
import           Control.Monad                  (forever)
import           Control.Applicative            ((<|>))
import           Control.Exception              (catch, SomeException(SomeException), throwIO, evaluate, try)
import qualified Data.Aeson                     as A
import qualified Data.ByteString.Lazy           as BL
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as TE
import qualified Data.Text.Lazy                 as TL
import qualified Data.Text.Lazy.Builder         as TB
import           Data.Maybe                     (isJust)
import           Data.Void                      (Void, absurd)
import           Network.HTTP.Types             (status200, status406, hAccept)
import           Network.HTTP.Media             (matchAccept, (//))
import           Network.WebSockets             (ServerApp, requestPath)
import qualified Network.WebSockets             as WS
import           Network.WebSockets.Connection  (ConnectionOptions, Connection, pendingRequest, rejectRequest, acceptRequest, forkPingThread, receiveData, receiveDataMessage, sendTextData, sendClose, sendCloseCode)
import           Network.Wai                    (Application, Middleware, responseLBS, requestHeaders)
import           Network.Wai.Handler.WebSockets (websocketsOr)

import qualified Replica.VDOM                   as V
import qualified Replica.VDOM.Render            as R
import           Replica.Run.Types              (Event(evtClientFrame), Update(UpdateDOM, ReplaceDOM),SessionAttachingError(SessionDoesntExist, SessionAlreadyAttached) ,SessionEventError(IllformedData))
import           Replica.Run.Log                (Log, rlog)
import qualified Replica.Run.Log                as L
import           Replica.Run.Session            (Session, Frame(frameVdom, frameNumber))
import qualified Replica.Run.Session            as S
import           Replica.Run.SessionID          (SessionID)
import qualified Replica.Run.SessionID          as SID
import           Replica.Run.SessionManager     (SessionManage)
import qualified Replica.Run.SessionManager     as SM

data Config res st = Config
  { cfgTitle                   :: T.Text
  , cfgHeader                  :: V.HTML
  , cfgWSConnectionOptions     :: ConnectionOptions
  , cfgMiddleware              :: Middleware
  , cfgLogAction               :: Co.LogAction IO (Ch.Time, Log)
  , cfgWSInitialConnectLimit   :: Ch.Timespan      -- ^ Time limit for first connect
  , cfgWSReconnectionSpanLimit :: Ch.Timespan      -- ^ limit for re-connecting span
  , cfgResourceAquire          :: IO res
  , cfgResourceRelease         :: res -> IO ()
  , cfgInitial                 :: res -> st
  , cfgStep                    :: (st -> IO (Maybe (V.HTML, st, Event -> Maybe (IO ()))))
  }

-- | Create replica application.
app :: Config res st -> (Application -> IO a) -> IO a
app cfg@Config{..} cb = do
  sm <- SM.initialize smcfg
  let wapp = websocketApp sm
  let bapp = cfgMiddleware $ backupApp cfg sm
  withWorker (SM.manageWorker sm) $ cb (websocketsOr cfgWSConnectionOptions wapp bapp)
  where
    smcfg = SM.Config
      { SM.cfgLogAction = Co.cmapM tagTime cfgLogAction
      , SM.cfgWSInitialConnectLimit = cfgWSInitialConnectLimit
      , SM.cfgWSReconnectionSpanLimit = cfgWSReconnectionSpanLimit
      }
    tagTime a = (,) <$> Ch.now <*> pure a

encodeToWsPath :: SessionID -> T.Text
encodeToWsPath sid = "/" <> SID.encodeSessionId sid

decodeFromWsPath :: T.Text -> Maybe SessionID
decodeFromWsPath wspath = SID.decodeSessionId (T.drop 1 wspath)

backupApp :: Config res st -> SessionManage -> Application
backupApp Config{..} sm req respond
  | isAcceptable = do
      v <- SM.preRender sm scfg
      case v of
        Nothing -> do
          respond $ responseLBS status200 [] ""
        Just (sid, body) -> do
          rlog sm $ L.InfoLog $ L.HTTPPrerender sid
          let html = V.ssrHtml cfgTitle (encodeToWsPath sid) cfgHeader body
          respond $ responseLBS status200 [("content-type", "text/html")] (renderHTML html)
  | otherwise = do
      -- 406 Not Accetable
      respond $ responseLBS status406 [] ""
  where
    scfg = S.Config
      { S.cfgResourceAquire = cfgResourceAquire
      , S.cfgResourceRelease = cfgResourceRelease
      , S.cfgInitial = cfgInitial
      , S.cfgStep = cfgStep
      }

    isAcceptable = isJust $ do
      ac <- lookup hAccept (requestHeaders req)
      matchAccept ["text" // "html"] ac

    renderHTML html = BL.fromStrict
      $ TE.encodeUtf8
      $ TL.toStrict
      $ TB.toLazyText
      $ R.renderHTML html

websocketApp :: SessionManage -> ServerApp
websocketApp sm pendingConn = do
  let wspath = TE.decodeUtf8 $ requestPath $ pendingRequest pendingConn
  case decodeFromWsPath wspath of
    Nothing -> do
      -- TODO: what happens to the client side?
      rlog sm $ L.ErrorLog $ L.WSInvalidWSPath wspath
      rejectRequest pendingConn "invalid ws path"
    Just sid -> do
      conn <- acceptRequest pendingConn
      forkPingThread conn 30
      rlog sm $ L.InfoLog $ L.WSAccepted sid
      r <- try $ SM.withSession sm sid $ \ses ->
        do
          v <- attachSessionToWebsocket conn ses
          case v of
            Just (SomeException e) -> internalErrorClosure conn sid e -- Session terminated by exception
            Nothing                -> normalClosure conn              -- Session terminated gracefully
        `catch` handleWSConnectionException conn sid ses
        `catch` handleSessionEventError conn sid ses
        `catch` handleSomeException conn sid ses

      -- サーバ側を再起動した場合、基本みんな再接続を試そうとして
      -- SessionDoesntExist エラーが発生する。ブラウザ側では再ロー
      -- ドを勧めるべし。
      case r of
        Left (e :: SessionAttachingError) ->
          case e of
            SessionDoesntExist     -> sessionNotFoundClosure conn <* rlog sm (L.InfoLog $ L.WSClosedByNotFound sid)
            SessionAlreadyAttached -> internalErrorClosure conn sid e
        Right _ ->
          pure ()
  where
    -- Websocket(https://github.com/jaspervdj/websockets/blob/0f7289b2b5426985046f1733413bb00012a27537/src/Network/WebSockets/Types.hs#L141)
    -- CloseRequest(1006): When the page was closed(atleast with firefox/chrome). Termiante Session.
    -- CloseRequest(???):  ??? Unexected Closure code
    -- ConnectionClosed: Most of the time. Connetion closed by TCP level unintentionaly. Leave contxt for re-connecting.
    handleWSConnectionException
      :: Connection
      -> SessionID
      -> Session
      -> WS.ConnectionException
      -> IO ()
    handleWSConnectionException conn sid ses e = case e of
      WS.CloseRequest code _
        | code == closeCodeGoingAway -> S.terminateSession ses <* rlog sm (L.InfoLog $ L.WSClosedByGoingAwayCode sid)
        | otherwise                 -> S.terminateSession ses <* rlog sm (L.ErrorLog $ L.WSClosedByUnexpectedCode sid (T.pack (show code)))
      WS.ConnectionClosed           -> rlog sm (L.InfoLog $ L.WSConnectionClosed sid)
      WS.ParseException _           -> S.terminateSession ses *> internalErrorClosure conn sid e
      WS.UnicodeException _         -> S.terminateSession ses *> internalErrorClosure conn sid e

    -- Rare. Problem occuered while event displatching/pasring.
    handleSessionEventError :: Connection -> SessionID -> Session -> SessionEventError -> IO ()
    handleSessionEventError conn sid ses e = do
      S.terminateSession ses
      internalErrorClosure conn sid e

    -- Rare. ??? don't know what happened
    handleSomeException :: Connection -> SessionID -> Session -> SomeException -> IO ()
    handleSomeException conn sid ses e = do
      S.terminateSession ses
      internalErrorClosure conn sid e

    -- We probably shouldn't show what caused the internal
    -- error. It'll just confuse users. For debug purpose use log.
    internalErrorClosure conn sid e = do
      _ <- trySome $ sendCloseCode conn closeCodeInternalError ("" :: T.Text)
      recieveCloseCode conn
      rlog sm $ L.ErrorLog $ L.WSClosedByInternalError sid (T.pack (show e))

    -- TODO: Currentlly doesn't work due to issue https://github.com/jaspervdj/websockets/issues/182
    -- recieveData を非同期例外で止めると、その後 connection が生きているのに Stream は close されてしまい、
    -- sendClose しようとすると ConnectionClosed 例外が発生する。
    -- fixed: https://github.com/kamoii/websockets/tree/handle-async-exception
    normalClosure conn = do
      _ <- trySome $ sendClose conn ("done" :: T.Text)
      recieveCloseCode conn

    -- IE とは区別して扱いため。
    --
    --  * Connection closed and before re-connecting it was terminated
    --  * Sever restarted
    --  * Rare case: SessionID which has valid form but
    --
    sessionNotFoundClosure conn = do
      _ <- trySome $ sendCloseCode conn closeCodeSessionNotFound ("" :: T.Text)
      recieveCloseCode conn

    -- After sending client the close code, we need to recieve
    -- close packet from client. If we don't do this and
    -- immideatly closed the tcp connection, it'll be an abnormal
    -- closure from client pov.
    recieveCloseCode conn = do
      _ <- trySome $ forever $ receiveDataMessage conn
      pure ()

    trySome = try @SomeException

    closeCodeInternalError   = 1011
    closeCodeGoingAway       = 1001
    closeCodeSessionNotFound = 4000 -- app original code

-- | Attacehes session to webcoket connection
--
-- This function will block until:
--
--   * Connection/Protocol-wise exception thrown, or
--   * Session ends gracefully, returning `Nothing`, or
--   * Session ends by exception, returning `Just SomeException`
--
-- Some notes:
--
--   * Assumes this session is not attached to any other connection. (※1)
--   * Connection/Protocol-wise exception(e.g. connection closed by client) will not stop the session.
--   * Atleast one frame will always be sent immiedatly. Even in a case where session is already
--     over/stopped by exception. In those case, it sends one frame and immiedeatly returns.
--   * First frame will be sent as `ReplaceDOM`, following frame will be sent as `UpdateDOM`
--   * In some rare case, when stepLoop is looping too fast, few frame might be get skipped,
--     but its not much a problems since those frame would have been shown only for a moment. (※2)
--
-- ※1
-- Actually, there is no problem attaching more than one connection to a single session.
-- We can do crazy things like 'read-only' attach and make a admin page where you can
-- peek users realtime page.
--
-- ※2
-- This framework is probably not meant for showing smooth animation.
-- We can actually mitigate this by preserving recent frames, not just the latest one.
-- Or use `chan` to distribute frames.
--
attachSessionToWebsocket :: Connection -> Session -> IO (Maybe SomeException)
attachSessionToWebsocket conn ses = withWorker eventLoop frameLoop
  where
    frameLoop :: IO (Maybe SomeException)
    frameLoop = do
      v@(f, _) <- atomically $ S.currentFrame ses
      sendTextData conn $ A.encode $ ReplaceDOM (frameVdom f)
      frameLoop' v

    frameLoop' :: (Frame, STM (Maybe Event)) -> IO (Maybe SomeException)
    frameLoop' (prevFrame, prevStepedBy) = do
      e <- atomically $  Left <$> getNewerFrame <|> Right <$> S.waitTerminate ses
      case e of
        Left (v@(frame,_), stepedBy) -> do
          diff <- evaluate $ V.diff (frameVdom prevFrame) (frameVdom frame)
          let updateDom = UpdateDOM (frameNumber frame) (evtClientFrame <$> stepedBy) diff
          sendTextData conn $ A.encode $ updateDom
          frameLoop' v
        Right result ->
          pure $ either Just (const Nothing) result
      where
        getNewerFrame = do
          v@(f, _) <- S.currentFrame ses
          check $ frameNumber f > frameNumber prevFrame
          s <- prevStepedBy  -- This should not block if we implement propertly. See `Session`'s documenation.
          pure (v, s)

    eventLoop :: IO Void
    eventLoop = forever $ do
      ev' <- A.decode <$> receiveData conn
      ev  <- maybe (throwIO IllformedData) pure ev'
      atomically $ S.feedEvent ses ev

-- | Runs a worker action alongside the provided continuation.
-- The worker will be automatically torn down when the continuation
-- terminates.
withWorker
  :: IO Void -- ^ Worker to run
  -> IO a
  -> IO a
withWorker worker cont =
  either absurd id <$> race worker cont
