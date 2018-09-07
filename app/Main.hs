{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent.Async
import Control.Concurrent.STM
  ( STM
  , TChan
  , TVar
  , atomically
  , dupTChan
  , newBroadcastTChan
  , newBroadcastTChanIO
  , newTVarIO
  , orElse
  , readTChan
  , readTVar
  , retry
  , writeTChan
  , writeTVar
  )
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
import Gamesite4.Domain.Room (RoomName(..))
import Gamesite4.Domain.User
import Gamesite4.Parsers
  ( WsRoomMsg(..)
  , parseRoomName
  , parseUsername
  , parseWsRoomMsg
  )
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
  { serverStateRooms :: Map RoomName ChatRoom
  }

newServerState :: ServerState
newServerState = ServerState M.empty

data Client = Client
  { clientUsername :: Username
  , clientConnection :: WS.Connection
  }

handleUserRedisMsg ::
     R.PubSubController -> TChan ByteString -> Username -> IO () -> IO ()
handleUserRedisMsg pubSubCtrl channel (Username username) action =
  bracket
    (R.addChannels pubSubCtrl [(channelName, callback)] [])
    id
    (const action)
  where
    channelName = encodeUtf8 $ "user:" <> username
    callback bytes = atomically $ writeTChan channel bytes

getRoomNameFromRedisChannel :: ByteString -> Maybe RoomName
getRoomNameFromRedisChannel = parseRoomName . decodeUtf8

receiveGameMsgs :: TVar ServerState -> R.PMessageCallback
receiveGameMsgs stateVar redisChannel bytes =
  atomically $ do
    state <- readTVar stateVar
    let maybeRoomId = getRoomNameFromRedisChannel redisChannel
    case maybeRoomId >>= (`M.lookup` serverStateRooms state) of
      Nothing -> pure ()
      Just room -> do
        let roomChannel = chatRoomChannel room
        writeTChan roomChannel bytes

main :: IO ()
main = do
  stateVar <- newTVarIO newServerState
  redisConnection <- R.checkedConnect R.defaultConnectInfo
  pubSubCtrl <- R.newPubSubController [] [("#*", receiveGameMsgs stateVar)]
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
  msg <- WS.receiveData conn
  case parseUsername msg of
    Nothing -> pure ()
    Just username@(Username rawUsername) -> do
      let client = Client username conn -- TODO client id
      WS.sendTextData conn $ "welcome " <> rawUsername
      WS.forkPingThread conn 30
      personalBroadcastChan <- newBroadcastTChanIO
      personalChan <- atomically $ dupTChan personalBroadcastChan
      clientChannels <- newTVarIO (ClientState personalChan M.empty)
      handleUserRedisMsg
        pubSubCtrl
        personalBroadcastChan
        (clientUsername client)
        (race_
           (respondForever client clientChannels)
           (receiveForever
              client
              redisConnection
              pubSubCtrl
              clientChannels
              stateVar))

data ClientState = ClientState
  { personalChannel :: TChan ByteString
  , roomChannels :: Map RoomName (TChan ByteString)
  }

addRoomChannel :: RoomName -> ChatRoom -> ClientState -> STM ClientState
addRoomChannel roomId room clientState = do
  let oldRoomChannels = roomChannels clientState
  channel <- dupTChan $ chatRoomChannel room
  let newRoomChannels = M.insert roomId channel oldRoomChannels
  pure $ clientState {roomChannels = newRoomChannels}

removeRoomChannel :: RoomName -> ClientState -> STM ClientState
removeRoomChannel roomId clientState =
  pure $ clientState {roomChannels = newRoomChannels}
  where
    oldRoomChannels = roomChannels clientState
    newRoomChannels = M.delete roomId oldRoomChannels

respondForever :: Client -> TVar ClientState -> IO ()
respondForever client channelsState =
  forever $ do
    msg <-
      atomically $ do
        ClientState pc rcs <- readTVar channelsState
        (decodeUtf8 <$> readTChan pc) `orElse` M.foldrWithKey f retry rcs
    WS.sendTextData conn msg
  where
    f (RoomName rn) a b =
      ((("#" <> rn <> " ") <>) <$> (decodeUtf8 <$> readTChan a)) `orElse` b
    conn = clientConnection client

stmModifyTVar :: TVar a -> (a -> STM a) -> STM ()
stmModifyTVar var f = do
  old <- readTVar var
  new <- f old
  writeTVar var new

receiveForever ::
     Client
  -> R.Connection
  -> R.PubSubController
  -> TVar ClientState
  -> TVar ServerState
  -> IO ()
receiveForever client redisConnection pubSubCtrl clientStateVar stateVar =
  forever loop
  where
    loop = do
      msg <- WS.receiveData (clientConnection client) :: IO Text
      case msg of
        _
          | "/join " `T.isPrefixOf` msg ->
            case parseRoomName msg of
              Nothing -> putStrLn "invalid join room request"
              Just roomId ->
                atomically $ do
                  state <- readTVar stateVar
                  let rooms = (serverStateRooms state)
                  case M.lookup roomId rooms of
                    Nothing -> do
                      room <- newChatRoom 1
                      stmModifyTVar clientStateVar (addRoomChannel roomId room)
                      writeTVar
                        stateVar
                        (state {serverStateRooms = M.insert roomId room rooms})
                    Just room -> do
                      stmModifyTVar clientStateVar (addRoomChannel roomId room)
                      writeTVar
                        stateVar
                        (state
                           { serverStateRooms =
                               M.adjust incrementClients roomId rooms
                           })
          | "/leave " `T.isPrefixOf` msg ->
            case parseRoomName msg of
              Nothing -> putStrLn "invalid leave room request"
              Just roomId ->
                atomically $ do
                  stmModifyTVar clientStateVar (removeRoomChannel roomId)
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
          | "#" `T.isPrefixOf` msg ->
            case parseWsRoomMsg msg of
              Nothing -> pure ()
              Just (WsRoomMsg roomName content) ->
                R.runRedis
                  redisConnection
                  (R.publish
                     (roomNameToRedisChannel roomName)
                     (encodeUtf8 content)) *>
                pure ()
          | "user:" `T.isPrefixOf` msg -> do
            _ <-
              R.runRedis redisConnection $ R.publish "user:123" (encodeUtf8 msg)
            pure ()
          | otherwise -> pure ()

roomNameToRedisChannel :: RoomName -> ByteString
roomNameToRedisChannel (RoomName rn) = "#" <> encodeUtf8 rn
