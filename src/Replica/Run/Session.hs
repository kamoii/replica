{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
module Replica.Run.Session
  ( Session
  , Config(..)
  , terminateSession
  , isTerminatedSTM
  , firstStep
  , firstStep'
  ) where

import           Control.Concurrent.Async       (Async, async, race, cancel, pollSTM)
import           Control.Concurrent.STM         (TMVar, TQueue, TVar, STM, atomically, retry, throwSTM
                                                , newTVar, readTVar, writeTVar
                                                , newTMVar, newEmptyTMVar, tryPutTMVar, readTMVar, isEmptyTMVar
                                                , newTQueue, readTQueue)
import           Control.Monad                  (join, forever)
import           Control.Applicative            ((<|>))
import           Control.Exception              (evaluate, mask, mask_, onException, finally)
import           Data.Maybe                     (isJust)
import           Data.Bool                      (bool)
import           Data.Void                      (Void, absurd)
import           Data.IORef                     (newIORef, atomicModifyIORef)

import qualified Replica.VDOM                   as V
import           Replica.Run.Types              (Event(evtClientFrame), SessionEventError(InvalidEvent))

-- | Session
--
--  NOTES:
--
--  * For every frame, its corresponding TMVar should get a value before the next (frame,stepedBy) is written.
--    Only exception to this is when exception occurs, last setted frame's `stepedBy` could be empty forever.
--
-- TODO: TMVar in a TVar. Is that a good idea?
-- TODO: Is name `Session` appropiate?
data Config res st = Config
  { cfgResourceAquire           :: IO res
  , cfgResourceRelease          :: res -> IO ()
  , cfgInitial                  :: res -> st
  , cfgStep                     :: (st -> IO (Maybe (V.HTML, st, Event -> Maybe (IO ()))))
  }

data Session = Session
  { sesFrame      :: TVar (Frame, TMVar (Maybe Event))
  , sesEventQueue :: TQueue Event   -- TBqueue might be better
  , sesThread     :: Async ()
  }

data Frame = Frame
  { frameNumber :: Int
  , frameVdom :: V.HTML
  , frameFire :: Event -> Maybe (IO ())
  }

-- | Kill Session
-- |
-- | Do nothing if the session has already terminated.
-- | Blocks until the session is actually terminated.
terminateSession :: Session -> IO ()
terminateSession Session{sesThread} = cancel sesThread

-- | Check Session is terminated(gracefully or with exception)
-- | Doesn't block.
isTerminatedSTM :: Session -> STM Bool
isTerminatedSTM Session{sesThread} = isJust <$> pollSTM sesThread

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
-- Session, もしくは IO () のどちらかが一方だけが必ず呼ばれる必要があ
-- る。後者は、Session を開始したくない場合に利用する(例えば一定時間立っ
-- ても browser が繋げに来なかった場合、など)。
--
-- リソース獲得及び解放ハンドラは mask された状態で実行される
--
-- Implementation notes:
-- 全体を onException で囲めないのは Nohting の場合は例外が発生していないが
-- `releaseRes` を呼び出さないといけないため。
firstStep :: Config res st -> IO (Maybe (V.HTML, IO Session, IO ()))
firstStep Config{..} =
  firstStep' cfgResourceAquire cfgResourceRelease cfgInitial cfgStep

firstStep'
  :: IO res
  -> (res -> IO ())
  -> (res -> st)
  -> (st -> IO (Maybe (V.HTML, st, Event -> Maybe (IO ()))))
  -> IO (Maybe (V.HTML, IO Session, IO ()))
firstStep' acquireRes releaseRes_ initial step = mask $ \restore -> do
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
          , startSession release step (vdom, st, fire)
          , release
          )

startSession
  :: IO ()
  -> (st -> IO (Maybe (V.HTML, st, Event -> Maybe (IO ()))))
  -> (V.HTML, st, Event -> Maybe (IO ()))
  -> IO Session
startSession release step (vdom, st, fire) = flip onException release $ do
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
  pure $ Session fv qv th
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
