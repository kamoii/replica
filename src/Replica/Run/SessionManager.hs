{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
module Replica.Run.SessionManager
  ( SessionManage
  , Config(..)
  , initialize
  , preRender
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

releaseSession :: SessionManage ->  SessionID -> (Session, TVar SessionState) -> Ch.Time -> STM ()
releaseSession SessionManage{..} sesId (ses, stateVar) now = do
  let deadline = cfgWSInitialConnectLimit smConfig `add` now
  b <- Ses.isTerminatedSTM ses
  if b
    then modifyTVar' smSesMap $ M.delete sesId
    else do
      writeTVar stateVar CMSOrphan
      modifyTVar' smOrphans $ PSQ.insert sesId deadline ses

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
-- TODO: use appconfig inside SessionManage
preRender :: SessionManage -> Ses.Config res st -> IO (Maybe (SessionID, V.HTML))
preRender rapp scfg = do
  mask $ \restore -> do
    s <- restore $ Ses.firstStep scfg
    case s of
      Nothing -> pure Nothing
      Just (initialVdom, startSession', _release) -> do
        -- NOTE: _release は使わずに即コンテキストを動き始める。この実装方針で問題ないのか？
        -- Take care not to lost session, or else we'll leak threads.
        ses <- startSession'
        flip onException (Ses.terminateSession ses) $ do
          sesId <- genSessionId
          now <- Ch.now
          dl <- atomically $ addOrphan rapp sesId ses now
          rlog rapp $ L.InfoLog $ L.InfoOrphanAdded sesId dl
          pure $ Just (sesId, initialVdom)

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
withSession rapp sesId cb = bracket req rel (cb . fst)
  where
    req = do
      atomically (acquireSession rapp sesId)
        <* rlog rapp (L.InfoLog (L.InfoOrpanAttached sesId))
    rel r = do
      now <- Ch.now
      atomically (releaseSession rapp sesId r now)
        <* rlog rapp (L.InfoLog (L.InfoBackToOrphan sesId))

manageWorker :: SessionManage -> IO Void
manageWorker rapp@SessionManage{..} =
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
        orphans <- atomically $ pickTargetOrphans rapp queue (max dl now)
        -- TODO: 確実に terminate したか確認したほうがいい？
        for_ orphans $ \(sesId,ses) -> async
          $ Ses.terminateSession ses <* rlog rapp (L.InfoLog (L.InfoOrpanTerminated sesId))

    fromEither (Left a)  = a
    fromEither (Right a) = a
