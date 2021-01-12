{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

module Replica.Run.Session (
    Session,
    Config (..),
    Frame (..),
    TerminatedReason (..),
    currentFrame,
    waitTerminate,
    feedEvent,
    terminateSession,
    isTerminated,
    terminatedReason,
    firstStep,
    firstStep',
) where

import Control.Applicative ((<|>))
import Control.Concurrent.Async (Async, async, cancel, pollSTM, race, waitCatchSTM)
import Control.Concurrent.STM (
    STM,
    TMVar,
    TQueue,
    TVar,
    atomically,
    isEmptyTMVar,
    newEmptyTMVar,
    newTMVar,
    newTQueue,
    newTVar,
    readTMVar,
    readTQueue,
    readTVar,
    retry,
    throwSTM,
    tryPutTMVar,
    writeTQueue,
    writeTVar,
 )
import Control.Exception (SomeException, evaluate, finally, mask, mask_, onException)
import Control.Monad (forever, join)
import Data.Bool (bool)
import Data.IORef (atomicModifyIORef, newIORef)
import Data.Maybe (isJust)
import Data.Void (Void, absurd)

import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Resource (ResourceT)
import qualified Control.Monad.Trans.Resource as RI
import Replica.Run.Types (Event (evtClientFrame), SessionEventError (InvalidEvent))
import qualified Replica.VDOM as V

{- | Session

  NOTES:

  * For every frame, its corresponding TMVar should get a value before the next (frame,stepedBy) is written.
    Only exception to this is when exception occurs, last setted frame's `stepedBy` could be empty forever.

 TODO: TMVar in a TVar. Is that a good idea?
 TODO: Is name `Session` appropiate?
-}
data Config state = Config
    { cfgInitial :: ResourceT IO state
    , cfgStep :: state -> ResourceT IO (Maybe (V.HTML, state, Event -> Maybe (IO ())))
    }

data Session = Session
    { sesFrame :: TVar (Frame, TMVar (Maybe Event))
    , sesEventQueue :: TQueue Event -- TBqueue might be better
    , sesThread :: Async ()
    }

data Frame = Frame
    { frameNumber :: Int
    , frameVdom :: V.HTML
    , frameFire :: Event -> Maybe (IO ())
    }

data TerminatedReason
    = TerminatedGracefully
    | TerminatedByException SomeException

{- | Current frame.
 | There is aleays a frame(even for terminated frames).
-}
currentFrame :: Session -> STM (Frame, STM (Maybe Event))
currentFrame Session{sesFrame} = do
    (f, v) <- readTVar sesFrame
    pure (f, readTMVar v)

-- | Wait till session terminates.
waitTerminate :: Session -> STM (Either SomeException ())
waitTerminate Session{sesThread} =
    waitCatchSTM sesThread

feedEvent :: Session -> Event -> STM ()
feedEvent Session{sesEventQueue} = writeTQueue sesEventQueue

{- | Kill Session
 |
 | Do nothing if the session has already terminated.
 | Blocks until the session is actually terminated.
-}
terminateSession :: Session -> IO ()
terminateSession Session{sesThread} = cancel sesThread

{- | Check Session is terminated(gracefully or with exception)
 | Doesn't block.
-}
isTerminated :: Session -> STM Bool
isTerminated Session{sesThread} = isJust <$> pollSTM sesThread

terminatedReason :: Session -> STM (Maybe TerminatedReason)
terminatedReason Session{sesThread} = do
    e <- pollSTM sesThread
    pure $ either TerminatedByException (const TerminatedGracefully) <$> e

{- | Execute the first step.

 In rare case, the app might not create any VDOM and gracefuly
 end. In such case, `Nothing` is returned.

 Don't execute while mask.

 About Resource management
  * リソースが獲得されたなら、firstSteps関数が

 もし `firstStep`関数が無事完了し、Just を返したならば、返り値の IO
 Session, もしくは IO () のどちらかが一方だけが必ず呼ばれる必要があ
 る。後者は、Session を開始したくない場合に利用する(例えば一定時間立っ
 ても browser が繋げに来なかった場合、など)。

 リソース獲得及び解放ハンドラは mask された状態で実行される

 Implementation notes:
 全体を onException で囲めないのは Nohting の場合は例外が発生していないが
 `releaseRes` を呼び出さないといけないため。
-}
firstStep :: Config state -> IO (Maybe (V.HTML, IO Session, IO ()))
firstStep Config{..} =
    firstStep' cfgInitial cfgStep

firstStep' ::
    ResourceT IO state ->
    (state -> ResourceT IO (Maybe (V.HTML, state, Event -> Maybe (IO ())))) ->
    IO (Maybe (V.HTML, IO Session, IO ()))
firstStep' initial step = mask $ \restore -> do
    doneVar <- newIORef False
    rstate <- RI.createInternalState
    let release = mkRelease doneVar rstate
    flip onException release $ do
        r <- restore . flip RI.runInternalState rstate $ step =<< initial
        case r of
            Nothing -> do
                release
                pure Nothing
            Just (_vdom, state, fire) -> do
                vdom <- evaluate _vdom
                pure $
                    Just
                        ( vdom
                        , startSession release step rstate (vdom, state, fire)
                        , release
                        )
  where
    -- Make sure that `closeInternalState v` is called once.
    -- Do we need it??
    mkRelease doneVar rstate = mask_ $ do
        b <- atomicModifyIORef doneVar (True,)
        if b then pure () else RI.closeInternalState rstate

startSession ::
    IO () ->
    (st -> ResourceT IO (Maybe (V.HTML, st, Event -> Maybe (IO ())))) ->
    RI.InternalState ->
    (V.HTML, st, Event -> Maybe (IO ())) ->
    IO Session
startSession release step rstate (vdom, st, fire) = flip onException release $ do
    let frame0 = Frame 0 vdom (const $ Just $ pure ())
    let frame1 = Frame 1 vdom fire
    (fv, qv) <- atomically $ do
        r <- newTMVar Nothing
        f <- newTVar (frame0, r)
        q <- newTQueue
        pure (f, q)
    th <-
        async $
            withWorker
                (fireLoop (getNewFrame fv) (getEvent qv))
                (stepLoop (setNewFrame fv) step st frame1 `RI.runInternalState` rstate `finally` release)
    pure $ Session fv qv th
  where
    setNewFrame var f = atomically $ do
        r <- newEmptyTMVar
        writeTVar var (f, r)
        pure r

    getNewFrame var = do
        v@(_, r) <- readTVar var
        bool retry (pure v) =<< isEmptyTMVar r

    getEvent que = readTQueue que

{- | stepLoop

 Every step starts with showing user the frame. After that we wait for a step to proceed.
 Step could be procceded by either:

   1) Client-side's event, which is recieved as `Event`, or
   2) Server-side event(e.g. io action returning a value)

 Every frame has corresponding `TMVar (Maybe Event)` called `stepedBy`. It is initally empty.
 It is filled whith `Event` when case (1), and filled with `Nothing` when case (2). (※1)
 New frame won't be created and setted before we fill current frame's `stepedBy`.

 ※1 Unfortunatlly, we don't have a garuntee that step was actually procceded by client-side event when
 `stepBy` is filled with `Just Event`. When we receive a dispatchable event, we fill `stepBy`
 before actually firing it. While firing the event, servier-side event could procceed the step.
-}
stepLoop ::
    (Frame -> IO (TMVar (Maybe Event))) ->
    (st -> ResourceT IO (Maybe (V.HTML, st, Event -> Maybe (IO ())))) ->
    st ->
    Frame ->
    ResourceT IO ()
stepLoop setNewFrame step st frame = do
    stepedBy <- liftIO $ setNewFrame frame
    r <- step st
    _ <- liftIO . atomically $ tryPutTMVar stepedBy Nothing
    case r of
        Nothing -> pure ()
        Just (_newVdom, newSt, newFire) -> do
            newVdom <- liftIO $ evaluate _newVdom
            let newFrame = Frame (frameNumber frame + 1) newVdom newFire
            stepLoop setNewFrame step newSt newFrame

{- | fireLoop

 NOTE:
 Don't foregt that STM's (<|>) prefers left(its not fair like mvar).
 Because of (1), at (2) `stepedBy` could be already filled even though its in the same STM action.
-}
fireLoop ::
    STM (Frame, TMVar (Maybe Event)) ->
    STM Event ->
    IO Void
fireLoop getNewFrame getEvent = forever $ do
    (frame, stepedBy) <- atomically getNewFrame
    let act = atomically $ do
            r <- Left <$> getEvent <|> Right <$> readTMVar stepedBy -- (1)
            case r of
                Left ev -> case frameFire frame ev of
                    Nothing
                        | evtClientFrame ev < frameNumber frame -> pure $ join act
                        | otherwise -> throwSTM InvalidEvent
                    Just fire' -> bool (pure ()) fire' <$> tryPutTMVar stepedBy (Just ev) -- (2)
                Right _ -> pure $ pure ()
    join act

{- | Runs a worker action alongside the provided continuation.
 The worker will be automatically torn down when the continuation
 terminates.
-}
withWorker ::
    -- | Worker to run
    IO Void ->
    IO a ->
    IO a
withWorker worker cont =
    either absurd id <$> race worker cont
