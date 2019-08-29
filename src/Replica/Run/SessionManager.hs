{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE MultiWayIf #-}
module Replica.Run.SessionManager
  ( SessionManage
  , Config(..)
  , initialize
  , preRender
  , PreRenderResult(..)
  , withSession
  , manageWorker
  ) where

import qualified Colog.Core                     as Co
import qualified Chronos                        as Ch
import           Torsor                         (add, difference, scale)
import           Control.Concurrent             (threadDelay)
import           Control.Concurrent.Async       (async, race)
import           Control.Concurrent.STM         (TVar, STM, atomically, retry, throwSTM, newTVar, readTVar, writeTVar, modifyTVar')
import           Control.Monad                  (forever, when)
import           Control.Exception              (mask, mask_, onException, bracket)
import qualified Data.OrdPSQ                    as PSQ
import qualified Data.Map                       as M
import qualified Data.Text                      as T
import           Data.Function                  ((&))
import           Data.Foldable                  (for_)
import           Data.Void                      (Void)


import qualified Replica.VDOM                   as V
import           Replica.Run.Types              (SessionAttachingError(SessionDoesntExist, SessionAlreadyAttached))
import           Replica.Run.Log                (Log, rlog)
import qualified Replica.Run.Log                as L
import           Replica.Run.Session            (Session)
import qualified Replica.Run.Session            as Ses
import           Replica.Run.SessionID          (SessionID, genSessionId)

data Config = Config
  { cfgLogAction                :: Co.LogAction IO Log
  , cfgWSInitialConnectLimit    :: Ch.Timespan      -- ^ Time limit for first connect
  , cfgWSReconnectionSpanLimit  :: Ch.Timespan      -- ^ limit for re-connecting span
  }

data SessionManage = SessionManage
  { smConfig    :: Config
  , smSesMap    :: TVar (M.Map SessionID (Session, TVar SessionState))
  , smOrphans0  :: TVar (PSQ.OrdPSQ SessionID Ch.Time Session)   -- ^ 初期接続待ち
  , smOrphans   :: TVar (PSQ.OrdPSQ SessionID Ch.Time Session)   -- ^ 再接続待ち
  }

instance Co.HasLog SessionManage Log IO where
  getLogAction = cfgLogAction . smConfig
  setLogAction a env@SessionManage{ smConfig } =
    env { smConfig = smConfig { cfgLogAction = a } }

data SessionState
  = CMSOrphan
  | CMSAttached
  deriving (Eq, Show)

-- | STM primitives(privates)

-- returns deadline
addOrphan :: SessionManage -> SessionID -> Session -> Ch.Time -> STM Ch.Time
addOrphan SessionManage{..} sesId ses now = do
  let deadline = cfgWSInitialConnectLimit smConfig `add` now
  stateVar <- newTVar CMSOrphan
  modifyTVar' smSesMap   $ M.insert sesId (ses, stateVar)
  modifyTVar' smOrphans0 $ PSQ.insert sesId deadline ses
  pure deadline

acquireSession :: SessionManage -> SessionID -> STM (Session, TVar SessionState)
acquireSession SessionManage{..} sesId = do
  sesMap          <- readTVar smSesMap
  (ses, stateVar) <- M.lookup sesId sesMap & maybe (throwSTM SessionDoesntExist) pure
  state           <- readTVar stateVar
  case state of
    CMSAttached ->
      throwSTM SessionAlreadyAttached
    CMSOrphan   -> do
      writeTVar stateVar CMSAttached
      modifyTVar' smOrphans0 $ PSQ.delete sesId
      modifyTVar' smOrphans  $ PSQ.delete sesId
      pure (ses, stateVar)

releaseSession
  :: SessionManage
  -> SessionID
  -> (Session, TVar SessionState)
  -> Ch.Time
  -> STM (Maybe Ses.TerminatedReason)
releaseSession SessionManage{..} sesId (ses, stateVar) now = do
  r <- Ses.terminatedReason ses
  case r of
    Just _ -> do
      modifyTVar' smSesMap $ M.delete sesId
    Nothing -> do
      let deadline = cfgWSInitialConnectLimit smConfig `add` now
      writeTVar stateVar CMSOrphan
      modifyTVar' smOrphans $ PSQ.insert sesId deadline ses
  pure r

-- Get the most near deadline. Doesn't pop the queue.
-- If the queue is empty, block till first item arrives.
firstDeadline :: TVar (PSQ.OrdPSQ k Ch.Time v) -> STM Ch.Time
firstDeadline orphansVar = do
  orphans <- readTVar orphansVar
  case PSQ.findMin orphans of
    Nothing -> retry
    Just (_, t, _) -> pure t

-- Targets to terminate. Targets are removed from smSesMap
-- 現在より 0.1s 以内のものはまとめて停止対象とする(
pickTargetOrphans
  :: SessionManage
  -> TVar (PSQ.OrdPSQ SessionID Ch.Time Session)
  -> Ch.Time
  -> STM [(SessionID, Session)]
pickTargetOrphans SessionManage{smSesMap} orphansVar now = do
  let dl = (100 `scale` millisecond) `add` now
  orphans <- readTVar orphansVar
  (orphans', targets) <- go dl orphans []
  writeTVar orphansVar orphans'
  pure targets
  where
    go deadline que acc = do
      case PSQ.findMin que of
        Just (sesId, t, ses)
          | t <= deadline -> do
              modifyTVar' smSesMap $ M.delete sesId
              go deadline (PSQ.deleteMin que) ((sesId,ses) : acc)
        _ -> pure (que, acc)

    millisecond = Ch.Timespan 1000000


-- |

initialize :: Config -> IO SessionManage
initialize cfg =
  atomically $ SessionManage cfg <$> newTVar mempty <*> newTVar PSQ.empty <*> newTVar PSQ.empty

-- | Server-side rendering
-- | For rare case, the application could end without generating.
-- |
-- | if `onlyPrerender` is True, after we get first HTML, session is
-- | not started(also resources is released if any) and not added as
-- | orphan.
data PreRenderResult
  = PRRNothing
  | PRROnlyPrerender V.HTML
  | PRRSessionStarted SessionID V.HTML

preRender :: SessionManage -> Ses.Config res st -> Bool -> IO PreRenderResult
preRender sm scfg onlyPreRender =
  mask $ \restore -> do
    s <- restore $ Ses.firstStep scfg
    case s of
      Nothing ->
        pure PRRNothing
      Just (initialVdom, startSession', release) -> do
        if
          | onlyPreRender -> do
              -- TODO: Should ignore exception raised in `release` ?
              release
              pure $ PRROnlyPrerender initialVdom
          | otherwise -> do
              ses <- startSession'
              flip onException (Ses.terminateSession ses) $ do
                sesId <- genSessionId
                rlog sm $ L.InfoLog $ L.SessionCreated sesId
                now <- Ch.now
                _dl <- atomically $ addOrphan sm sesId ses now
                pure $ PRRSessionStarted sesId initialVdom

-- | 取り出して
-- |
-- | 例外を投げるのは以下のケース
-- |
-- |  1) SessionID に対応する ses が存在しない
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
withSession :: SessionManage -> SessionID -> (Session -> IO a) -> IO a
withSession sm sid cb = bracket req rel (cb . fst)
  where
    req = do
      s <- atomically $ acquireSession sm sid
      rlog sm $ L.InfoLog $ L.SessionAttached sid
      pure s

    rel r = do
      now <- Ch.now
      tr <- atomically $ releaseSession sm sid r now
      case tr of
        Just Ses.TerminatedGracefully ->
          rlog sm $ L.InfoLog $ L.SessionTerminated sid "gracefully"
        Just (Ses.TerminatedByException e) ->
          rlog sm $ L.InfoLog $ L.SessionTerminated sid ("exception: " <> T.pack (show e))
        Nothing ->
          rlog sm $ L.InfoLog $ L.SessionDetached sid

manageWorker :: SessionManage -> IO Void
manageWorker sm@SessionManage{..} =
  fromEither <$> race (orphanTerminator smOrphans0) (orphanTerminator smOrphans)
  where
    orphanTerminator :: TVar (PSQ.OrdPSQ SessionID Ch.Time Session) -> IO Void
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
        orphans <- atomically $ pickTargetOrphans sm queue (max dl now)
        -- TODO: 確実に terminate したか確認したほうがいい？
        for_ orphans $ \(sesId,ses) -> async
          $ Ses.terminateSession ses <* rlog sm (L.InfoLog (L.SessionTerminated sesId "deadline"))

    fromEither (Left a)  = a
    fromEither (Right a) = a
