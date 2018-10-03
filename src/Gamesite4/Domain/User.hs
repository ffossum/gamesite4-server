module Gamesite4.Domain.User where

import           Data.Text                      ( Text )
import qualified Data.Text                     as T

newtype UserId =
  UserId Int
  deriving (Eq, Ord, Show)

newtype Username =
  Username Text
  deriving (Eq, Show)
