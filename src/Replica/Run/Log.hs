{-# LANGUAGE OverloadedStrings   #-}
module Replica.Run.Log where

import qualified Colog.Core                     as Co
import qualified Chronos                        as Ch
import qualified Data.Text                      as T
import Replica.Run.SessionID (SessionID, encodeSessionId)

data Log
  = DebugLog T.Text
  | InfoLog  InfoLog
  | ErrorLog  ErrorLog

data InfoLog
  = InfoOrphanAdded SessionID Ch.Time
  | InfoOrpanAttached SessionID
  | InfoBackToOrphan SessionID
  | InfoOrpanTerminated SessionID

data ErrorLog
  = ErrorWSClosedByInternalError String

rlogSeverity :: Log -> Co.Severity
rlogSeverity (InfoLog _)  = Co.Info
rlogSeverity (DebugLog _) = Co.Debug
rlogSeverity (ErrorLog _) = Co.Error

rlogToText :: Log -> T.Text
rlogToText (DebugLog t) = t
rlogToText (InfoLog l)  = case l of
  InfoOrphanAdded sesId dl        -> "New orpahan addded: " <> encodeSessionId sesId <> ", deadline: " <> encodeTime dl
  InfoOrpanAttached sesId         -> "Orphan attaced: " <> encodeSessionId sesId
  InfoBackToOrphan sesId          -> "Back to orphan: " <> encodeSessionId sesId
  InfoOrpanTerminated sesId       -> "Orphan terminated: " <> encodeSessionId sesId
rlogToText (ErrorLog l)  = case l of
  ErrorWSClosedByInternalError mes -> "Closed websocket connecion by internal error: " <> T.pack mes

-- | Thin-utility for co-log's logging
rlog :: Co.HasLog env msg m => env -> msg -> m ()
rlog env msg = Co.getLogAction env Co.<& msg

encodeTime :: Ch.Time -> T.Text
encodeTime time =
  Ch.encode_YmdHMSz offsetFormat subsecondPrecision Ch.w3c offsetDatetime
  where
    jstOffset          = Ch.Offset (9 * 60)
    offsetDatetime     = Ch.timeToOffsetDatetime jstOffset time
    offsetFormat       = Ch.OffsetFormatColonOff
    subsecondPrecision = Ch.SubsecondPrecisionFixed 2
