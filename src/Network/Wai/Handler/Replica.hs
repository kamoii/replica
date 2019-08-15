{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Replica where

import qualified Colog.Core                     as Co
import qualified Chronos                        as Ch
import           Torsor                         (add, difference, scale)
import           Control.Concurrent             (threadDelay)
import           Control.Concurrent.Async       (Async, async, waitCatchSTM, race, cancel, pollSTM)
import           Control.Concurrent.STM         (TMVar, TQueue, TVar, STM, atomically, retry, check, throwSTM
                                                , newTVar, readTVar, writeTVar, modifyTVar'
                                                , newTMVar, newEmptyTMVar, tryPutTMVar, readTMVar, isEmptyTMVar
                                                , newTQueue, writeTQueue, readTQueue)
import           Control.Monad                  (join, forever, guard, when)
import           Control.Applicative            ((<|>))
import           Control.Exception              (catch, SomeException(SomeException),Exception, throwIO, evaluate, try, mask, mask_, onException, finally, bracket)
import           Crypto.Random                  (MonadRandom(getRandomBytes))

import           Data.Aeson                     ((.:), (.=))
import qualified Data.Aeson                     as A
import qualified Data.OrdPSQ                    as PSQ

import qualified Data.ByteString                as B
import qualified Data.ByteString.Lazy           as BL
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as TE
import qualified Data.Text.Lazy                 as TL
import qualified Data.Text.Lazy.Builder         as TB
import qualified Data.Map                       as M
import           Data.Maybe                     (isJust)
import           Data.Bool                      (bool)
import           Data.Function                  ((&))
import           Data.Foldable                  (for_)
import           Data.Void                      (Void, absurd)
import           Data.IORef                     (newIORef, atomicModifyIORef)
import           Network.HTTP.Types             (status200, status406, hAccept)
import           Network.HTTP.Media             (matchAccept, (//))

import           Network.WebSockets             (ServerApp, requestPath)
import qualified Network.WebSockets             as WS
import           Network.WebSockets.Connection  (ConnectionOptions, Connection, pendingRequest, rejectRequest, acceptRequest, forkPingThread, receiveData, receiveDataMessage, sendTextData, sendClose, sendCloseCode)
import           Network.Wai                    (Application, Middleware, responseLBS, requestHeaders)
import           Network.Wai.Handler.WebSockets (websocketsOr)
import           Text.Hex                       (encodeHex, decodeHex)

import qualified Replica.VDOM                   as V
import qualified Replica.VDOM.Render            as R

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

data AppConfig = AppConfig
  { acfgTitle               :: T.Text
  , acfgHeader              :: V.HTML
  , acfgWSConnectionOptions :: ConnectionOptions
  , acfgMiddleware          :: Middleware
  }

data ReplicaAppConfig = forall st res. ReplicaAppConfig
  { rcfgLogAction                :: Co.LogAction IO ReplicaLog
  , rcfgWSInitialConnectLimit    :: Ch.Timespan      -- ^ Time limit for first connect
  , rcfgWSReconnectionSpanLimit  :: Ch.Timespan      -- ^ limit for re-connecting span
  , rcfgResourceAquire           :: IO res
  , rcfgResourceRelease          :: res -> IO ()
  , rcfgInitial                  :: res -> st
  , rcfgStep                     :: (st -> IO (Maybe (V.HTML, st, Event -> Maybe (IO ()))))
  }

-- | Create replica application.
app :: forall a. AppConfig -> ReplicaAppConfig -> (Application -> IO a) -> IO a
app AppConfig{..} rcfg cb = do
  rapp <- initializeReplicaApp rcfg
  let wapp = websocketApp rapp
  let bapp = acfgMiddleware $ backupApp rapp
  withWorker (manageReplicaApp rapp) $ cb (websocketsOr acfgWSConnectionOptions wapp bapp)
  where
    encodeToWsPath :: ContextID -> T.Text
    encodeToWsPath ctxId = "/" <> encodeContextId ctxId

    decodeFromWsPath :: T.Text -> Maybe ContextID
    decodeFromWsPath wspath = decodeContextId (T.drop 1 wspath)

    backupApp :: ReplicaApp -> Application
    backupApp rapp req respond
      | isAcceptable = do
          v <- preRender rapp
          case v of
            Nothing -> do
              respond $ responseLBS status200 [] ""
            Just (ctxId, body) -> do
              let html = V.ssrHtml acfgTitle (encodeToWsPath ctxId) acfgHeader body
              respond $ responseLBS status200 [("content-type", "text/html")] (renderHTML html)
      | otherwise = do
          -- 406 Not Accetable
          respond $ responseLBS status406 [] ""
      where
        isAcceptable = isJust $ do
          ac <- lookup hAccept (requestHeaders req)
          matchAccept ["text" // "html"] ac

        renderHTML html = BL.fromStrict
          $ TE.encodeUtf8
          $ TL.toStrict
          $ TB.toLazyText
          $ R.renderHTML html

    websocketApp :: ReplicaApp -> ServerApp
    websocketApp rapp pendingConn = do
      let wspath = TE.decodeUtf8 $ requestPath $ pendingRequest pendingConn
      case decodeFromWsPath wspath of
        Nothing -> do
          -- TODO: what happens to the client side?
          rejectRequest pendingConn "invalid ws path"
        Just ctxId -> do
          conn <- acceptRequest pendingConn
          forkPingThread conn 30
          r <- try $ withContext rapp ctxId $ \ctx ->
            do
              v <- attachContextToWebsocket conn ctx
              case v of
                Just (SomeException e) -> internalErrorClosure conn e -- Context terminated by exception
                Nothing                -> normalClosure conn          -- Context terminated gracefully
            `catch` handleWSConnectionException conn ctx
            `catch` handleContextEventError conn ctx
            `catch` handleSomeException conn ctx

          case r of
            Left (e :: ContextAttachingError) ->
              -- サーバ側を再起動した場合、基本みんな再接続を試そうと
              -- してこのエラーが発生する。ブラウザ側では再ロードを勧
              -- めるべし。
              -- TODO: Internal Error とは違うな... セッションが切れました？のほうが近いかも。
              internalErrorClosure conn e
            Right _ ->
              pure ()
      where
        -- Websocket(https://github.com/jaspervdj/websockets/blob/0f7289b2b5426985046f1733413bb00012a27537/src/Network/WebSockets/Types.hs#L141)
        -- CloseRequest(1006): When the page was closed(atleast with firefox/chrome). Termiante Context.
        -- CloseRequest(???):  ??? Unexected Closure code
        -- ConnectionClosed: Most of the time. Connetion closed by TCP level unintentionaly. Leave contxt for re-connecting.
        handleWSConnectionException :: Connection -> Context -> WS.ConnectionException -> IO ()
        handleWSConnectionException conn ctx e = case e of
          WS.CloseRequest code _
            | code == closeCodeGoingAway -> terminateContext ctx
            | otherwise                 -> terminateContext ctx
          WS.ConnectionClosed           -> pure ()
          WS.ParseException _           -> terminateContext ctx *> internalErrorClosure conn e
          WS.UnicodeException _         -> terminateContext ctx *> internalErrorClosure conn e

        -- Rare. Problem occuered while event displatching/pasring.
        handleContextEventError :: Connection -> Context -> ContextEventError -> IO ()
        handleContextEventError conn ctx e =
          terminateContext ctx *> internalErrorClosure conn e

        -- Rare. ??? don't know what happened
        handleSomeException :: Connection -> Context -> SomeException -> IO ()
        handleSomeException conn ctx e =
          terminateContext ctx *> internalErrorClosure conn e

        internalErrorClosure conn e = do
          _ <- try @SomeException $ sendCloseCode conn closeCodeInternalError (T.pack $ show e)
          recieveCloseCode conn
          rlog rapp $ ReplicaErrorLog $ ErrorWSClosedByInternalError (show e)

        -- TODO: Currentlly doesn't work due to issue https://github.com/jaspervdj/websockets/issues/182
        -- recieveData を非同期例外で止めると、その後 connection が生きているのに Stream は close されてしまい、
        -- sendClose しようとすると ConnectionClosed 例外が発生する。
        -- fixed: https://github.com/kamoii/websockets/tree/handle-async-exception
        normalClosure conn = do
          _ <- try @SomeException $ sendClose conn ("done" :: T.Text)
          recieveCloseCode conn
          rlog rapp $ ReplicaDebugLog $ "Closing gracefully"

        -- After sending client the close code, we need to recieve
        -- close packet from client. If we don't do this and
        -- immideatly closed the tcp connection, it'll be an abnormal
        -- closure from client pov.
        recieveCloseCode conn = do
          _ <- try @SomeException $ forever $ receiveDataMessage conn
          pure ()

        closeCodeInternalError = 1011
        closeCodeGoingAway     = 1001

-- | ReplicaApp
-- |
-- | Context の状態(running, termianted) と直交して Context へのアタッチ状態を持つ
-- |
-- |  1. orphan       アタッチされていない。Context は running/terminated 両方のケースがありうる
-- |  2. attached     クライストにアタッチされている。基本running中だが、最初から terminated なものがアタッチされる可能性はある。
-- |
-- | ※第三の状態、suspended (prerender はしたが、そこで止めている状態)も考えられるが、
-- | そのような状態は基本初回接続までの間(ここで失敗するケースはレアケース)なので、管理
-- | をややこしくするよりは、もう動かしておいて orphan 状態として扱ったほうがいいという
-- | 判断をしている。
-- |
-- | ただしスクレイピングなど js が有効でない環境からのアクセスの場合があるので初回アタッチ
-- | だけは時間厳しめでやったほうがいいかも。
-- |
-- |
-- |
-- |

data ReplicaApp = ReplicaApp
  { rappConfig   :: ReplicaAppConfig
  , rappCtxMap   :: TVar (M.Map ContextID (Context, TVar ContextManageState))
  , rappOrphans0 :: TVar (PSQ.OrdPSQ ContextID Ch.Time Context)   -- ^ 初期接続待ち
  , rappOrphans  :: TVar (PSQ.OrdPSQ ContextID Ch.Time Context)   -- ^ 再接続待ち
  }

data ContextManageState
  = CMSOrphan
  | CMSAttached
  deriving (Eq, Show)

data ReplicaLog
  = ReplicaDebugLog T.Text
  | ReplicaInfoLog  ReplicaInfoLog
  | ReplicaErrorLog  ReplicaErrorLog

data ReplicaInfoLog
  = InfoOrphanAdded ContextID Ch.Time
  | InfoOrpanAttached ContextID
  | InfoBackToOrphan ContextID
  | InfoOrpanTerminated ContextID

data ReplicaErrorLog
  = ErrorWSClosedByInternalError String

rlogSeverity :: ReplicaLog -> Co.Severity
rlogSeverity (ReplicaInfoLog _)  = Co.Info
rlogSeverity (ReplicaDebugLog _) = Co.Debug
rlogSeverity (ReplicaErrorLog _) = Co.Error

rlogToText :: ReplicaLog -> T.Text
rlogToText (ReplicaDebugLog t) = t
rlogToText (ReplicaInfoLog l)  = case l of
  InfoOrphanAdded ctxId dl        -> "New orpahan addded: " <> encodeContextId ctxId <> ", deadline: " <> encodeTime dl
  InfoOrpanAttached ctxId         -> "Orphan attaced: " <> encodeContextId ctxId
  InfoBackToOrphan ctxId          -> "Back to orphan: " <> encodeContextId ctxId
  InfoOrpanTerminated ctxId       -> "Orphan terminated: " <> encodeContextId ctxId
rlogToText (ReplicaErrorLog l)  = case l of
  ErrorWSClosedByInternalError mes -> "Closed websocket connecion by internal error: " <> T.pack mes

rlog :: ReplicaApp -> ReplicaLog -> IO ()
rlog ReplicaApp{ rappConfig = ReplicaAppConfig{rcfgLogAction} } message =
  rcfgLogAction Co.<& message

rlogDebug :: ReplicaApp -> T.Text -> IO ()
rlogDebug rapp txt = rlog rapp (ReplicaDebugLog txt)

encodeTime :: Ch.Time -> T.Text
encodeTime time =
  Ch.encode_YmdHMSz offsetFormat subsecondPrecision Ch.w3c offsetDatetime
  where
    jstOffset          = Ch.Offset (9 * 60)
    offsetDatetime     = Ch.timeToOffsetDatetime jstOffset time
    offsetFormat       = Ch.OffsetFormatColonOff
    subsecondPrecision = Ch.SubsecondPrecisionFixed 2

-- | STM primitives(privates)

-- returns deadline
addOrphan :: ReplicaApp -> ContextID -> Context -> Ch.Time -> STM Ch.Time
addOrphan ReplicaApp{..} ctxId ctx now = do
  let deadline = rcfgWSInitialConnectLimit rappConfig `add` now
  stateVar <- newTVar CMSOrphan
  modifyTVar' rappCtxMap   $ M.insert ctxId (ctx, stateVar)
  modifyTVar' rappOrphans0 $ PSQ.insert ctxId deadline ctx
  pure deadline

acquireContext :: ReplicaApp -> ContextID -> STM (Context, TVar ContextManageState)
acquireContext ReplicaApp{..} ctxId = do
  ctxMap          <- readTVar rappCtxMap
  (ctx, stateVar) <- M.lookup ctxId ctxMap & maybe (throwSTM ContextDoesntExist) pure
  state           <- readTVar stateVar
  case state of
    CMSAttached ->
      throwSTM ContextAlreadyAttached
    CMSOrphan   -> do
      writeTVar stateVar CMSAttached
      modifyTVar' rappOrphans0 $ PSQ.delete ctxId
      modifyTVar' rappOrphans  $ PSQ.delete ctxId
      pure (ctx, stateVar)

releaseContext :: ReplicaApp ->  ContextID -> (Context, TVar ContextManageState) -> Ch.Time -> STM ()
releaseContext ReplicaApp{..} ctxId (ctx, stateVar) now = do
  let deadline = rcfgWSInitialConnectLimit rappConfig `add` now
  b <- isTerminatedSTM ctx
  if b
    then modifyTVar' rappCtxMap $ M.delete ctxId
    else do
      writeTVar stateVar CMSOrphan
      modifyTVar' rappOrphans $ PSQ.insert ctxId deadline ctx

-- Get the most near deadline. Doesn't pop the queue.
-- If the queue is empty, block till first item arrives.
firstDeadline :: TVar (PSQ.OrdPSQ k Ch.Time v) -> STM Ch.Time
firstDeadline orphansVar = do
  orphans <- readTVar orphansVar
  case PSQ.findMin orphans of
    Nothing -> retry
    Just (_, t, _) -> pure t

-- Targets to terminate. Targets are removed from rappCtxMap
-- 現在より 0.1s 以内のものはまとめて停止対象とする(
pickTargetOrphans
  :: ReplicaApp
  -> TVar (PSQ.OrdPSQ ContextID Ch.Time Context)
  -> Ch.Time
  -> STM [(ContextID, Context)]
pickTargetOrphans ReplicaApp{rappCtxMap} orphansVar now = do
  let dl = (100 `scale` millisecond) `add` now
  orphans <- readTVar orphansVar
  (orphans', targets) <- go dl orphans []
  writeTVar orphansVar orphans'
  pure targets
  where
    go deadline que acc = do
      case PSQ.findMin que of
        Just (ctxId, t, ctx)
          | t <= deadline -> do
              modifyTVar' rappCtxMap $ M.delete ctxId
              go deadline (PSQ.deleteMin que) ((ctxId,ctx) : acc)
        _ -> pure (que, acc)

    millisecond = Ch.Timespan 1000000


-- |

initializeReplicaApp :: ReplicaAppConfig -> IO ReplicaApp
initializeReplicaApp rcfg =
  atomically $ ReplicaApp rcfg <$> newTVar mempty <*> newTVar PSQ.empty <*> newTVar PSQ.empty

-- | Server-side rendering
-- | For rare case, the application could end without generating.
-- TODO: use appconfig inside ReplicaApp
preRender :: ReplicaApp -> IO (Maybe (ContextID, V.HTML))
preRender rapp@ReplicaApp{rappConfig} = do
  mask $ \restore -> do
    s <- restore $ firstStep' rappConfig
    case s of
      Nothing -> pure Nothing
      Just (initialVdom, startContext', _release) -> do
        -- NOTE: _release は使わずに即コンテキストを動き始める。この実装方針で問題ないのか？
        -- Take care not to lost context, or else we'll leak threads.
        ctx <- startContext'
        flip onException (terminateContext ctx) $ do
          ctxId <- genContextId
          now <- Ch.now
          dl <- atomically $ addOrphan rapp ctxId ctx now
          rlog rapp $ ReplicaInfoLog $ InfoOrphanAdded ctxId dl
          pure $ Just (ctxId, initialVdom)
  where
    -- let ReplicaAppConfig{..} = rappConfig だとエラーが出るので？
    firstStep' ReplicaAppConfig{..} =
      firstStep rcfgResourceAquire rcfgResourceRelease rcfgInitial rcfgStep

data ContextAttachingError
  = ContextDoesntExist
  | ContextAlreadyAttached
  deriving (Eq, Show)

instance Exception ContextAttachingError

-- | 取り出して
-- |
-- | 例外を投げるのは以下のケース
-- |
-- |  1) ContextID に対応する ctx が存在しない
-- |  2) 存在するが、既に attached 状態である
-- |  3) コンテキストを渡したコールバックが例外を投げた場合
-- |
-- | つまり値が帰るのは、コールバックが実行されかつ例外を投げることなく終了した場合のみ。
-- | コールバックが終了(正常・異常終了両方でも)した時点でコテンキストも終了状態であれば、
-- | 再度 orpohan にに戻さずコンテキストは破棄される。コンテキストが終了状態でなければ、
-- | 再接続を待つため orphan として管理される。
-- |
-- | 例え orpahn 中にコンテキストが終了してしまったとしても callback は呼ばれる。
-- |
withContext :: ReplicaApp -> ContextID -> (Context -> IO a) -> IO a
withContext rapp ctxId cb = bracket req rel (cb . fst)
  where
    req = do
      atomically (acquireContext rapp ctxId)
        <* rlog rapp (ReplicaInfoLog (InfoOrpanAttached ctxId))
    rel r = do
      now <- Ch.now
      atomically (releaseContext rapp ctxId r now)
        <* rlog rapp (ReplicaInfoLog (InfoBackToOrphan ctxId))

manageReplicaApp :: ReplicaApp -> IO Void
manageReplicaApp rapp@ReplicaApp{..} =
  fromEither <$> race (orphanTerminator rappOrphans0) (orphanTerminator rappOrphans)
  where
    orphanTerminator :: TVar (PSQ.OrdPSQ ContextID Ch.Time Context) -> IO Void
    orphanTerminator queue = forever $ do
      dl <- atomically $ firstDeadline queue
      now <- Ch.now
      -- deadline まで時間があれば寝とく。初期接続と再接続のqueueを分離しているので
      -- より近い deadline が割り込むことはない。
      when (dl > now) $ do
        let diff = dl `difference` now                          -- Timespan is nanosecond(10^-9)
        threadDelay $ fromIntegral (Ch.getTimespan diff) `div` 1000 -- threadDelay recieves microseconds(10^-6)
      mask_ $ do
        -- 取り出した後に terminate が実行できないと leak するので mask の中で。
        -- ゼロ件の可能性もあるので注意(直近の deadline のものが attach された場合)
        orphans <- atomically $ pickTargetOrphans rapp queue (max dl now)
        -- TODO: 確実に terminate したか確認したほうがいい？
        for_ orphans $ \(ctxId,ctx) -> async
          $ terminateContext ctx <* rlog rapp (ReplicaInfoLog (InfoOrpanTerminated ctxId))

    fromEither (Left a)  = a
    fromEither (Right a) = a


newtype ContextID = ContextID B.ByteString
  deriving (Eq, Ord)

contextIdByteLength :: Int
contextIdByteLength = 16

genContextId :: MonadRandom m => m ContextID
genContextId = ContextID <$> getRandomBytes contextIdByteLength

-- | ContextID's text representation, safe to use as url path segment
encodeContextId :: ContextID -> T.Text
encodeContextId (ContextID bs) = encodeHex bs

decodeContextId :: T.Text -> Maybe ContextID
decodeContextId t = do
  bs <- decodeHex t
  guard $ B.length bs == contextIdByteLength
  pure $ ContextID bs

-- These exceptions are not to ment recoverable. Should stop the context.
-- TODO: Make it more rich to make debug easier?
-- TODO: Split to ContextEventError and ProtocolError
data ContextEventError
  = IllformedData
  | InvalidEvent
  deriving Show

instance Exception ContextEventError

-- | Attacehes context to webcoket connection
--
-- This function will block until:
--
--   * Connection/Protocol-wise exception thrown, or
--   * Context ends gracefully, returning `Nothing`, or
--   * Context ends by exception, returning `Just SomeException`
--
-- Some notes:
--
--   * Assumes this context is not attached to any other connection. (※1)
--   * Connection/Protocol-wise exception(e.g. connection closed by client) will not stop the context.
--   * Atleast one frame will always be sent immiedatly. Even in a case where context is already
--     over/stopped by exception. In those case, it sends one frame and immiedeatly returns.
--   * First frame will be sent as `ReplaceDOM`, following frame will be sent as `UpdateDOM`
--   * In some rare case, when stepLoop is looping too fast, few frame might be get skipped,
--     but its not much a problems since those frame would have been shown only for a moment. (※2)
--
-- ※1
-- Actually, there is no problem attaching more than one connection to a single context.
-- We can do crazy things like 'read-only' attach and make a admin page where you can
-- peek users realtime page.
--
-- ※2
-- This framework is probably not meant for showing smooth animation.
-- We can actually mitigate this by preserving recent frames, not just the latest one.
-- Or use `chan` to distribute frames.
--
attachContextToWebsocket :: Connection -> Context -> IO (Maybe SomeException)
attachContextToWebsocket conn ctx = withWorker eventLoop frameLoop
  where
    frameLoop :: IO (Maybe SomeException)
    frameLoop = do
      v@(f, _) <- atomically $ readTVar (ctxFrame ctx)
      sendTextData conn $ A.encode $ ReplaceDOM (frameVdom f)
      frameLoop' v

    frameLoop' :: (Frame, TMVar (Maybe Event)) -> IO (Maybe SomeException)
    frameLoop' (prevFrame, prevStepedBy) = do
      e <- atomically $  Left <$> getNewerFrame <|> Right <$> waitCatchSTM (ctxThread ctx)
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
          v@(f, _) <- readTVar (ctxFrame ctx)
          check $ frameNumber f > frameNumber prevFrame
          s <- readTMVar prevStepedBy  -- This should not block if we implement propertly. See `Context`'s documenation.
          pure (v, s)

    eventLoop :: IO Void
    eventLoop = forever $ do
      ev' <- A.decode <$> receiveData conn
      ev  <- maybe (throwIO IllformedData) pure ev'
      atomically $ writeTQueue (ctxEventQueue ctx) ev

-- | Context
--
--  NOTES:
--
--  * For every frame, its corresponding TMVar should get a value before the next (frame,stepedBy) is written.
--    Only exception to this is when exception occurs, last setted frame's `stepedBy` could be empty forever.
--
-- TODO: TMVar in a TVar. Is that a good idea?
-- TODO: Is name `Context` appropiate?
data Context = Context
  { ctxFrame      :: TVar (Frame, TMVar (Maybe Event))
  , ctxEventQueue :: TQueue Event   -- TBqueue might be better
  , ctxThread     :: Async ()
  }

data Frame = Frame
  { frameNumber :: Int
  , frameVdom :: V.HTML
  , frameFire :: Event -> Maybe (IO ())
  }

-- | Kill Context
-- |
-- | Do nothing if the context has already terminated.
-- | Blocks until the context is actually terminated.
terminateContext :: Context -> IO ()
terminateContext Context{ctxThread} = cancel ctxThread

-- | Check Context is terminated(gracefully or with exception)
-- | Doesn't block.
isTerminatedSTM :: Context -> STM Bool
isTerminatedSTM Context{ctxThread} = isJust <$> pollSTM ctxThread

-- | Execute the first step.
--
-- In rare case, the app might not create any VDOM and gracefuly
-- end. In such case, `Nothing` is returned.
--
-- Don't execute while mask.
--
-- About Resource management
--  * リソースが獲得されたなら、firstSteps関数が
--
-- もし `firstStep`関数が無事完了し、Just を返したならば、返り値の IO
-- Context, もしくは IO () のどちらかが一方だけが必ず呼ばれる必要があ
-- る。後者は、Context を開始したくない場合に利用する(例えば一定時間立っ
-- ても browser が繋げに来なかった場合、など)。
--
-- リソース獲得及び解放ハンドラは mask された状態で実行される
--
-- Implementation notes:
-- 全体を onException で囲めないのは Nohting の場合は例外が発生していないが
-- `releaseRes` を呼び出さないといけないため。
firstStep
  :: IO res
  -> (res -> IO ())
  -> (res -> st)
  -> (st -> IO (Maybe (V.HTML, st, Event -> Maybe (IO ()))))
  -> IO (Maybe (V.HTML, IO Context, IO ()))
firstStep acquireRes releaseRes_ initial step = mask $ \restore -> do
  v <- acquireRes
  i <- newIORef False
  -- Make sure that `releaseRes_ v` is called once.
  let release = mask_ $ do
        b <- atomicModifyIORef i $ \done -> (True, done)
        if b then pure () else releaseRes_ v
  flip onException release $ do
    r <- restore $ step (initial v)
    case r of
      Nothing -> do
        release
        pure Nothing
      Just (_vdom, st, fire) -> do
        vdom <- evaluate _vdom
        pure $ Just
          ( vdom
          , startContext release step (vdom, st, fire)
          , release
          )

startContext
  :: IO ()
  -> (st -> IO (Maybe (V.HTML, st, Event -> Maybe (IO ()))))
  -> (V.HTML, st, Event -> Maybe (IO ()))
  -> IO Context
startContext release step (vdom, st, fire) = flip onException release $ do
  let frame0 = Frame 0 vdom (const $ Just $ pure ())
  let frame1 = Frame 1 vdom fire
  (fv, qv) <- atomically $ do
    r <- newTMVar Nothing
    f <- newTVar (frame0, r)
    q <- newTQueue
    pure (f, q)
  th <- async $ flip finally release $ withWorker
    (fireLoop (getNewFrame fv) (getEvent qv))
    (stepLoop (setNewFrame fv) step st frame1)
  pure $ Context fv qv th
  where
    setNewFrame var f = atomically $ do
      r <- newEmptyTMVar
      writeTVar var (f,r)
      pure r

    getNewFrame var = do
      v@(_, r) <- readTVar var
      bool retry (pure v) =<< isEmptyTMVar r

    getEvent que = readTQueue que

-- | stepLoop
--
-- Every step starts with showing user the frame. After that we wait for a step to proceed.
-- Step could be procceded by either:
--
--   1) Client-side's event, which is recieved as `Event`, or
--   2) Server-side event(e.g. io action returning a value)
--
-- Every frame has corresponding `TMVar (Maybe Event)` called `stepedBy`. It is initally empty.
-- It is filled whith `Event` when case (1), and filled with `Nothing` when case (2). (※1)
-- New frame won't be created and setted before we fill current frame's `stepedBy`.
--
-- ※1 Unfortunatlly, we don't have a garuntee that step was actually procceded by client-side event when
-- `stepBy` is filled with `Just Event`. When we receive a dispatchable event, we fill `stepBy`
-- before actually firing it. While firing the event, servier-side event could procceed the step.
stepLoop
  :: (Frame -> IO (TMVar (Maybe Event)))
  -> (st -> IO (Maybe (V.HTML, st, Event -> Maybe (IO ()))))
  -> st
  -> Frame
  -> IO ()
stepLoop setNewFrame step st frame = do
  stepedBy <- setNewFrame frame
  r <- step st
  _ <- atomically $ tryPutTMVar stepedBy Nothing
  case r of
    Nothing -> pure ()
    Just (_newVdom, newSt, newFire) -> do
      newVdom <- evaluate _newVdom
      let newFrame = Frame (frameNumber frame + 1) newVdom newFire
      stepLoop setNewFrame step newSt newFrame


-- | fireLoop
--
--
-- NOTE:
-- Don't foregt that STM's (<|>) prefers left(its not fair like mvar).
-- Because of (1), at (2) `stepedBy` could be already filled even though its in the same STM action.
fireLoop
  :: STM (Frame, TMVar (Maybe Event))
  -> STM Event
  -> IO Void
fireLoop getNewFrame getEvent = forever $ do
  (frame, stepedBy) <- atomically getNewFrame
  let act = atomically $ do
        r <- Left <$> getEvent <|> Right <$> readTMVar stepedBy -- (1)
        case r of
          Left ev -> case frameFire frame ev of
            Nothing
              | evtClientFrame ev < frameNumber frame -> pure $ join act
              | otherwise -> throwSTM InvalidEvent
            Just fire' -> bool (pure ()) fire' <$> tryPutTMVar stepedBy (Just ev)   -- (2)
          Right _ -> pure $ pure ()
  join act

-- | Runs a worker action alongside the provided continuation.
-- The worker will be automatically torn down when the continuation
-- terminates.
withWorker
  :: IO Void -- ^ Worker to run
  -> IO a
  -> IO a
withWorker worker cont =
  either absurd id <$> race worker cont
