{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
module Replica.Run.Types where

import           Control.Exception              (Exception)
import           Data.Aeson                     ((.:), (.=))
import qualified Data.Aeson                     as A
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
