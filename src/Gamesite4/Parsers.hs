{-# LANGUAGE OverloadedStrings #-}

module Gamesite4.Parsers where

import           Control.Applicative
import           Data.Attoparsec.Text
import           Data.Char
import           Data.Either.Combinators
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Gamesite4.Domain.Room          ( RoomName(..) )
import           Gamesite4.Domain.User          ( Username(..) )

parseUsername :: Text -> Maybe Username
parseUsername msg = Username <$> rightToMaybe (parseOnly parser msg)
  where parser = takeWhile1 isValidChar

isValidChar :: Char -> Bool
isValidChar c = isAlphaNum c || c `elem` ['-', '_']

parseRoomName :: Text -> Maybe RoomName
parseRoomName msg = rightToMaybe (parseOnly parser msg)
 where
  parser = do
    _  <- many (satisfy (/= '#'))
    _  <- char '#'
    rn <- takeWhile1 isValidChar
    pure $ RoomName rn

data WsRoomMsg =
  WsRoomMsg RoomName
            Text
  deriving (Show)

parseWsRoomMsg :: Text -> Maybe WsRoomMsg
parseWsRoomMsg msg = rightToMaybe (parseOnly parser msg)
 where
  parser = do
    _        <- char '#'
    roomName <- takeWhile1 isValidChar
    _        <- char ' '
    content  <- takeText
    pure $ WsRoomMsg (RoomName roomName) content
