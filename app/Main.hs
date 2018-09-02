{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent
       (MVar, modifyMVar, modifyMVar_, myThreadId, newMVar, readMVar,
        threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
       (STM, TChan, TVar, atomically, dupTChan, modifyTVar,
        newBroadcastTChan, newBroadcastTChanIO, newTChanIO, newTVarIO,
        orElse, readTChan, readTVar, readTVarIO, retry, writeTChan,
        writeTVar)
import Control.Exception
       (SomeException, bracket, bracket_, catch, finally)
import Control.Monad (forM_, forever)
import Data.ByteString (ByteString)
import Data.Char (isPunctuation, isSpace)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import qualified Data.Text.IO as T
import qualified Database.Redis as R
import qualified Network.WebSockets as WS
import TextShow

newtype UserId =
  UserId Int
  deriving (Eq, Show)

newtype RoomId =
  RoomId Int
  deriving (Eq, Ord)

data ChatRoomMsg
  = ClientJoined UserId
  | ClientLeft UserId

data ChatRoom = ChatRoom
  { chatRoomClients :: Int
  , chatRoomChannel :: ChatRoomChannel
  }

type ChatRoomChannel = TChan ByteString

newChatRoom :: Int -> STM ChatRoom
newChatRoom initialClients = ChatRoom initialClients <$> newBroadcastTChan

incrementClients :: ChatRoom -> ChatRoom
incrementClients room = room {chatRoomClients = chatRoomClients room + 1}

decrementClients :: ChatRoom -> ChatRoom
decrementClients room = room {chatRoomClients = chatRoomClients room - 1}

data ClientMsg =
  RoomMessage

type ChatRoomsState = Map RoomId ChatRoom

newChatRoomsState :: Map RoomId ChatRoom
newChatRoomsState = M.empty

type Client = (Text, WS.Connection)

handleUserChannelMsg :: R.PubSubController -> UserId -> IO () -> IO ()
handleUserChannelMsg pubSubCtrl (UserId userId) action =
  bracket
    (R.addChannels pubSubCtrl [(channelName, callback)] [])
    id
    (const action)
  where
    channelName = encodeUtf8 $ "user:" <> showt userId
    callback bytes = do
      T.putStrLn (decodeUtf8 bytes)
      pure ()

getRoomIdFromRedisChannel :: ByteString -> Maybe RoomId
getRoomIdFromRedisChannel redisChannel = Just (RoomId 123) -- TODO

receiveGameMsgs :: TVar ChatRoomsState -> R.PMessageCallback
receiveGameMsgs roomsStateVar redisChannel bytes =
  atomically $ do
    roomsState <- readTVar roomsStateVar
    let maybeRoomId = getRoomIdFromRedisChannel redisChannel
    case maybeRoomId >>= (`M.lookup` roomsState) of
      Nothing -> pure ()
      Just room -> do
        let roomChannel = chatRoomChannel room
        writeTChan roomChannel bytes

main :: IO ()
main = do
  tid <- myThreadId
  print $ "main thread id: " <> show tid
  roomsState <- newTVarIO newChatRoomsState
  redisConnection <- R.checkedConnect R.defaultConnectInfo
  pubSubCtrl <-
    R.newPubSubController [] [("room:*", receiveGameMsgs roomsState)]
  T.putStrLn "Starting server"
  race_
    (WS.runServer "127.0.0.1" 9160 $
     application redisConnection pubSubCtrl roomsState)
    (R.pubSubForever
       redisConnection
       pubSubCtrl
       (T.putStrLn "Redis pubsub active"))

application ::
     R.Connection -> R.PubSubController -> TVar ChatRoomsState -> WS.ServerApp
application redisConnection pubSubCtrl roomsState pending = do
  tid <- myThreadId
  print $ "req thread id: " <> show tid
  conn <- WS.acceptRequest pending
  WS.forkPingThread conn 30
  msg <- WS.receiveData conn
  case msg of
    _
      | not (prefix `T.isPrefixOf` msg) ->
        WS.sendTextData conn ("Wrong announcement" :: Text)
      | any ($ fst client) [T.null, T.any isPunctuation, T.any isSpace] ->
        WS.sendTextData
          conn
          ("Name cannot contain punctuation or whitespace, and cannot be empty" :: Text)
      | otherwise -> do
        clientChannels <- newClientChannels >>= newTVarIO
        handleUserChannelMsg
          pubSubCtrl
          (UserId 123)
          (race_
             (respondForever client clientChannels)
             (talk client redisConnection pubSubCtrl clientChannels roomsState))
      where prefix = "Hi! I am "
            client = (T.drop (T.length prefix) msg, conn)

getRoomIdFromWsMsg :: Text -> Maybe RoomId
getRoomIdFromWsMsg _ = Just (RoomId 123)

getUserIdFromWsMsg :: Text -> Maybe UserId
getUserIdFromWsMsg _ = Just (UserId 123)

data ClientChannels = ClientChannels
  { personalChannel :: TChan ByteString
  , roomChannels :: Map RoomId (TChan ByteString)
  }

newClientChannels :: IO ClientChannels
newClientChannels = do
  personal <- newTChanIO
  pure $ ClientChannels personal M.empty

addRoomChannel :: RoomId -> ChatRoom -> ClientChannels -> STM ClientChannels
addRoomChannel roomId room channels = do
  let oldRoomChannels = roomChannels channels
  channel <- dupTChan $ chatRoomChannel room
  let newRoomChannels = M.insert roomId channel oldRoomChannels
  pure $ channels {roomChannels = newRoomChannels}

removeRoomChannel :: RoomId -> ClientChannels -> STM ClientChannels
removeRoomChannel roomId channels =
  pure $ channels {roomChannels = newRoomChannels}
  where
    oldRoomChannels = roomChannels channels
    newRoomChannels = M.delete roomId oldRoomChannels

respondForever :: Client -> TVar ClientChannels -> IO ()
respondForever (user, conn) channelsState =
  forever $ do
    msg <-
      atomically $ do
        ClientChannels pc rcs <- readTVar channelsState
        foldr (orElse . readTChan) retry rcs
    T.putStrLn (decodeUtf8 msg)

stmModifyTVar :: TVar a -> (a -> STM a) -> STM ()
stmModifyTVar var f = do
  old <- readTVar var
  new <- f old
  writeTVar var new

talk ::
     Client
  -> R.Connection
  -> R.PubSubController
  -> TVar ClientChannels
  -> TVar ChatRoomsState
  -> IO ()
talk (user, conn) redisConnection pubSubCtrl channelsState roomsState =
  forever loop
  where
    loop = do
      msg <- WS.receiveData conn :: IO Text
      case msg of
        _
          | "join:" `T.isPrefixOf` msg ->
            case getRoomIdFromWsMsg msg of
              Nothing -> putStrLn "invalid join room request"
              Just roomId ->
                atomically $ do
                  rooms <- readTVar roomsState
                  case M.lookup roomId rooms of
                    Nothing -> do
                      room <- newChatRoom 1
                      stmModifyTVar channelsState (addRoomChannel roomId room)
                      writeTVar roomsState (M.insert roomId room rooms)
                    Just room -> do
                      stmModifyTVar channelsState (addRoomChannel roomId room)
                      writeTVar
                        roomsState
                        (M.adjust incrementClients roomId rooms)
          | "leave:" `T.isPrefixOf` msg ->
            case getRoomIdFromWsMsg msg of
              Nothing -> putStrLn "invalid leave room request"
              Just roomId ->
                atomically $ do
                  stmModifyTVar channelsState (removeRoomChannel roomId)
                  rooms <- readTVar roomsState
                  case M.lookup roomId rooms of
                    Nothing -> pure ()
                    Just room ->
                      let clients = chatRoomClients room
                      in if clients > 1
                           then writeTVar
                                  roomsState
                                  (M.adjust decrementClients roomId rooms)
                           else writeTVar roomsState (M.delete roomId rooms)
          | "room:" `T.isPrefixOf` msg -> do
            R.runRedis redisConnection $ R.publish "room:123" (encodeUtf8 msg)
            pure ()
          | "user:" `T.isPrefixOf` msg -> do
            R.runRedis redisConnection $ R.publish "user:123" (encodeUtf8 msg)
            pure ()
          | otherwise -> pure ()
