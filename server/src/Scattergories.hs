{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Scattergories
  ( ActiveGame
  , initGameWithHost
  , servePlayer
  , module X
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_)
import Control.Exception (fromException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (FromJSON, ToJSON, eitherDecode', encode)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Network.WebSockets
    ( Connection
    , ConnectionException(..)
    , receiveData
    , sendTextData
    , withPingThread
    )

import Scattergories.Errors as X
import Scattergories.Events as X
import Scattergories.Game as X
import Scattergories.Messages as X

data ActiveGame = ActiveGame
  { game        :: Game
  , playerConns :: Map PlayerName Connection
  }

initGameWithHost :: PlayerName -> ActiveGame
initGameWithHost host = ActiveGame
  { game = createGame host
  , playerConns = Map.empty
  }

servePlayer :: MVar ActiveGame -> PlayerName -> Connection -> IO ()
servePlayer activeGameVar playerName playerConn = do
  modifyMVar_ activeGameVar $ setupPlayer playerName playerConn

  withPingThread playerConn pingDelay postPing $ runLoop $ do
    event <- receiveJSONData playerConn
    modifyMVar_ activeGameVar $ \activeGame -> do
      let checkHost = unless (getHost (game activeGame) == playerName) $ throwIO NotHostError
      case event of
        StartRoundEvent -> checkHost >> startGameRound activeGame
        SubmitAnswersEvent{} -> undefined
        EndValidationEvent{} -> undefined
        EndGameEvent -> checkHost >> endGame activeGame
  where
    pingDelay = 30 -- seconds
    postPing = return ()

    -- continually run the given action, until a CloseRequest exception is thrown
    -- any other errors are sent to the client
    runLoop m = try m >>= \case
      Left e ->
        case fromException e of
          Just CloseRequest{} ->
            modifyMVar_ activeGameVar $ \activeGame ->
              pure activeGame
                { playerConns = Map.delete playerName (playerConns activeGame)
                }
          _ -> do
            let serverErr = fromMaybe (UnexpectedServerError e) (fromException e)
            sendJSONData playerConn $ mkError serverErr
            runLoop m
      Right _ -> runLoop m

{- Game mechanics -}

-- | If the game hasn't started yet, add the given player to the game and notify everyone of the
-- new arrival.
setupPlayer :: PlayerName -> Connection -> ActiveGame -> IO ActiveGame
setupPlayer playerName playerConn activeGame = do
  when (playerName `Map.member` playerConns activeGame) $
    throwIO $ CannotJoinGameError "you're already in the game"

  case getStatus $ game activeGame of
    GameStart -> notifyUpdatedPlayerList >> pure updatedActiveGame
    _ -> if playerName `Set.member` getPlayers (game activeGame)
      then pure activeGame
      else throwIO $ CannotJoinGameError "game already started without you"
  where
    updatedGame = initPlayer playerName (game activeGame)
    updatedActiveGame = activeGame
      { game = updatedGame
      , playerConns = Map.insert playerName playerConn (playerConns activeGame)
      }
    notifyUpdatedPlayerList = sendToAll updatedActiveGame $
      RefreshPlayerListMessage (getHost updatedGame) (Set.toList $ getPlayers updatedGame)

-- | Start a new round in the game.
startGameRound :: ActiveGame -> IO ActiveGame
startGameRound activeGame@ActiveGame{game} = do
  nextRoundNum <- case getStatus game of
    GameStart -> return 0
    GameRound RoundInfo{roundNum} RoundEnd -> return $ roundNum + 1
    GameRound _ _ -> throwIO $ UnexpectedStartRoundError "round isn't over"
    GameDone -> throwIO $ UnexpectedStartRoundError "game is done"

  newRound <- generateRound nextRoundNum
  let activeGame' = activeGame { game = startRound newRound game }

  sendToAll activeGame' $ StartRoundMessage newRound
  return activeGame'

-- | End the game.
endGame :: ActiveGame -> IO ActiveGame
endGame activeGame@ActiveGame{game} = do
  let activeGame' = activeGame { game = markGameDone game }
  sendToAll activeGame' EndGameMessage
  return activeGame'

{- WebSocket helpers -}

receiveJSONData :: FromJSON a => Connection -> IO a
receiveJSONData conn = either fail return . eitherDecode' =<< receiveData conn

sendJSONData :: ToJSON a => Connection -> a -> IO ()
sendJSONData conn = sendTextData conn . encode

sendToAll :: ActiveGame -> Message -> IO ()
sendToAll ActiveGame{playerConns} message =
  forM_ (Map.elems playerConns) $ \conn ->
    sendJSONData conn $ mkMessage message
