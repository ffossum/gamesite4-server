{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent.Async
import Control.Concurrent.STM
       (STM, TChan, TVar, atomically, dupTChan, newBroadcastTChan,
        newBroadcastTChanIO, newTVarIO, orElse, readTChan, readTVar, retry,
        writeTChan, writeTVar)
import Control.Exception (bracket)
import Control.Monad (forever)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import qualified Data.Text.IO as T
import qualified Database.Redis as R
import Gamesite4.Domain.Room
import Gamesite4.Domain.User
import qualified Network.WebSockets as WS
import TextShow

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

newtype ServerState = ServerState
  { serverStateRooms :: Map RoomId ChatRoom
  }

newServerState :: ServerState
newServerState = ServerState M.empty

data Client = Client
  { clientUserId :: UserId
  , clientConnection :: WS.Connection
  }

handleUserRedisMsg ::
     R.PubSubController -> TChan ByteString -> UserId -> IO () -> IO ()
handleUserRedisMsg pubSubCtrl channel (UserId userId) action =
  bracket
    (R.addChannels pubSubCtrl [(channelName, callback)] [])
    id
    (const action)
  where
    channelName = encodeUtf8 $ "user:" <> showt userId
    callback bytes = do
      T.putStrLn $ "handleUserRedisMsg: " <> decodeUtf8 bytes
      atomically $ writeTChan channel bytes

getRoomIdFromRedisChannel :: ByteString -> Maybe RoomId
getRoomIdFromRedisChannel redisChannel = Just (RoomId 123) -- TODO

receiveGameMsgs :: TVar ServerState -> R.PMessageCallback
receiveGameMsgs stateVar redisChannel bytes =
  atomically $ do
    state <- readTVar stateVar
    let maybeRoomId = getRoomIdFromRedisChannel redisChannel
    case maybeRoomId >>= (`M.lookup` serverStateRooms state) of
      Nothing -> pure ()
      Just room -> do
        let roomChannel = chatRoomChannel room
        writeTChan roomChannel bytes

main :: IO ()
main = do
  stateVar <- newTVarIO newServerState
  redisConnection <- R.checkedConnect R.defaultConnectInfo
  pubSubCtrl <- R.newPubSubController [] [("room:*", receiveGameMsgs stateVar)]
  T.putStrLn "Starting server"
  race_
    (WS.runServer "127.0.0.1" 9160 $
     application redisConnection pubSubCtrl stateVar)
    (R.pubSubForever
       redisConnection
       pubSubCtrl
       (T.putStrLn "Redis pubsub active"))

application ::
     R.Connection -> R.PubSubController -> TVar ServerState -> WS.ServerApp
application redisConnection pubSubCtrl stateVar pending = do
  conn <- WS.acceptRequest pending
  let client = Client (UserId 123) conn -- TODO client id
  WS.forkPingThread conn 30
  personalBroadcastChan <- newBroadcastTChanIO
  personalChan <- atomically $ dupTChan personalBroadcastChan
  clientChannels <- newTVarIO (ClientChannels personalChan M.empty)
  handleUserRedisMsg
    pubSubCtrl
    personalBroadcastChan
    (clientUserId client)
    (race_
       (respondForever client clientChannels)
       (talk client redisConnection pubSubCtrl clientChannels stateVar))

getRoomIdFromWsMsg :: Text -> Maybe RoomId
getRoomIdFromWsMsg _ = Just (RoomId 123)

getUserIdFromWsMsg :: Text -> Maybe UserId
getUserIdFromWsMsg _ = Just (UserId 123)

data ClientChannels = ClientChannels
  { personalChannel :: TChan ByteString
  , roomChannels :: Map RoomId (TChan ByteString)
  }

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
respondForever client channelsState =
  forever $ do
    msg <-
      atomically $ do
        ClientChannels pc rcs <- readTVar channelsState
        readTChan pc `orElse` foldr (orElse . readTChan) retry rcs
    T.putStrLn $ "respondForever: " <> decodeUtf8 msg

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
  -> TVar ServerState
  -> IO ()
talk client redisConnection pubSubCtrl channelsVar stateVar = forever loop
  where
    loop = do
      msg <- WS.receiveData (clientConnection client) :: IO Text
      case msg of
        _
          | "join:" `T.isPrefixOf` msg ->
            case getRoomIdFromWsMsg msg of
              Nothing -> putStrLn "invalid join room request"
              Just roomId ->
                atomically $ do
                  state <- readTVar stateVar
                  let rooms = (serverStateRooms state)
                  case M.lookup roomId rooms of
                    Nothing -> do
                      room <- newChatRoom 1
                      stmModifyTVar channelsVar (addRoomChannel roomId room)
                      writeTVar
                        stateVar
                        (state {serverStateRooms = M.insert roomId room rooms})
                    Just room -> do
                      stmModifyTVar channelsVar (addRoomChannel roomId room)
                      writeTVar
                        stateVar
                        (state
                         { serverStateRooms =
                             M.adjust incrementClients roomId rooms
                         })
          | "leave:" `T.isPrefixOf` msg ->
            case getRoomIdFromWsMsg msg of
              Nothing -> putStrLn "invalid leave room request"
              Just roomId ->
                atomically $ do
                  stmModifyTVar channelsVar (removeRoomChannel roomId)
                  state <- readTVar stateVar
                  let rooms = (serverStateRooms state)
                  case M.lookup roomId rooms of
                    Nothing -> pure ()
                    Just room ->
                      let clients = chatRoomClients room
                      in if clients > 1
                           then writeTVar
                                  stateVar
                                  (state
                                   { serverStateRooms =
                                       M.adjust decrementClients roomId rooms
                                   })
                           else writeTVar
                                  stateVar
                                  (state
                                   {serverStateRooms = M.delete roomId rooms})
          | "room:" `T.isPrefixOf` msg -> do
            _ <-
              R.runRedis redisConnection $ R.publish "room:123" (encodeUtf8 msg)
            pure ()
          | "user:" `T.isPrefixOf` msg -> do
            _ <-
              R.runRedis redisConnection $ R.publish "user:123" (encodeUtf8 msg)
            pure ()
          | otherwise -> pure ()
