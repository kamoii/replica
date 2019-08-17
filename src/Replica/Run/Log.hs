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
  = SessionCreated SessionID
  | SessionAttached SessionID
  | SessionDetached SessionID
  | SessionTerminated SessionID T.Text

data ErrorLog
  = WSClosedByInternalError SessionID T.Text
  | WSInvalidWSPath T.Text

severity :: Log -> Co.Severity
severity (InfoLog _)  = Co.Info
severity (DebugLog _) = Co.Debug
severity (ErrorLog _) = Co.Error

toText :: Log -> T.Text
toText (DebugLog t) = t
toText (InfoLog l)  = case l of
  SessionCreated sid           -> "[SID:" <> formatSid sid <> "] Session Created"
  SessionAttached sid          -> "[SID:" <> formatSid sid <> "] Session Attached"
  SessionDetached sid          -> "[SID:" <> formatSid sid <> "] Session Detached"
  SessionTerminated sid reason -> "[SID:" <> formatSid sid <> "] Session Terminated(" <> reason <> ")"
toText (ErrorLog l)  = case l of
  WSClosedByInternalError sid mes -> "[SID:" <> formatSid sid <> "] WS closed by internal error: " <> mes
  WSInvalidWSPath path            -> "Invalid websocket path: " <> path

formatSid :: SessionID -> T.Text
formatSid sid = T.take 6 (encodeSessionId sid) <> ".."

tag :: Log -> IO (Ch.Time, Co.Severity, T.Text)
tag l = do
  now <- Ch.now
  pure (now, severity l, toText l)

format :: (Ch.Time, Co.Severity, T.Text) -> T.Text
format (t, s, l) = encodeTime t <> " [" <> T.pack (show s) <> "] " <> l

-- | Thin-utility for co-log's logging
rlog :: Co.HasLog env msg m => env -> msg -> m ()
rlog env msg = Co.getLogAction env Co.<& msg

-- e.g. 2019-08-17T03:33:51.99+0900
encodeTime :: Ch.Time -> T.Text
encodeTime time =
  Ch.encode_YmdHMSz offsetFormat subsecondPrecision Ch.w3c offsetDatetime
  where
    jstOffset          = Ch.Offset (9 * 60)
    offsetDatetime     = Ch.timeToOffsetDatetime jstOffset time
    offsetFormat       = Ch.OffsetFormatColonOff
    subsecondPrecision = Ch.SubsecondPrecisionFixed 2
