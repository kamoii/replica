{-# LANGUAGE OverloadedStrings #-}

module Replica.VDOM.Types where

import Data.Aeson ((.=))
import qualified Data.Aeson as A
import qualified Data.Map as M
import qualified Data.Text as T

t :: T.Text -> T.Text
t = id

type HTML = [VDOM]

-- TODO: add note about difference about Text and RawText
data VDOM
    = VNode !T.Text !Attrs ![VDOM]
    | VLeaf !T.Text !Attrs
    | VText !T.Text
    | VRawText !T.Text

instance A.ToJSON VDOM where
    toJSON (VText text) =
        A.object
            [ "type" .= t "text"
            , "text" .= text
            ]
    toJSON (VRawText text) =
        A.object
            [ "type" .= t "text"
            , "text" .= text
            ]
    toJSON (VLeaf element attrs) =
        A.object
            [ "type" .= t "leaf"
            , "element" .= element
            , "attrs" .= attrs
            ]
    toJSON (VNode element attrs children) =
        A.object
            [ "type" .= t "node"
            , "element" .= element
            , "attrs" .= attrs
            , "children" .= children
            ]

type Attrs = M.Map T.Text Attr

-- TODO: Add a note why we need `AMap !Attrs'
data Attr
    = AText !T.Text
    | ABool !Bool
    | AEvent !(DOMEvent -> IO ())
    | AMap !Attrs

instance A.ToJSON Attr where
    toJSON (AText v) = A.String v
    toJSON (ABool v) = A.Bool v
    toJSON (AEvent _) = A.Null
    toJSON (AMap v) = A.toJSON $ fmap A.toJSON v

newtype DOMEvent = DOMEvent {getDOMEvent :: A.Value}
