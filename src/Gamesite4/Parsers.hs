{-# LANGUAGE OverloadedStrings #-}

module Gamesite4.Parsers where

import Control.Applicative
import Data.Attoparsec.Text
import Data.Char
import Data.Either.Combinators
import Data.Text (Text)
import qualified Data.Text as T
import Gamesite4.Domain.Room (RoomId(..))
import Gamesite4.Domain.User (Username(..))

data RoomMsg = RoomMsg
  { roomMsgRoomId :: RoomId
  , roomMsgContent :: Text
  } deriving (Show)

parseUsername :: Text -> Maybe Username
parseUsername msg = Username <$> rightToMaybe (parseOnly parser msg)
  where
    parser = takeWhile1 isUsernameChar

isUsernameChar :: Char -> Bool
isUsernameChar c = isAlphaNum c || c `elem` ['-', '_']

parseRoomId :: Text -> Maybe RoomId
parseRoomId msg = rightToMaybe (parseOnly parser msg)
  where
    parser = do
      _ <- many1 letter
      _ <- char ':'
      i <- decimal
      pure $ RoomId (fromIntegral i)
