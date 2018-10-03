module Gamesite4.Domain.Room where

import           Data.Text                      ( Text )

newtype RoomName =
  RoomName Text
  deriving (Eq, Ord, Show)
