{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Monad.IO.Class          (liftIO)
import qualified Data.ByteString                 as ByteString
import qualified System.Clock                    as Clock

import qualified Network.Tox.Encoding            as Encoding
import qualified Network.Tox.NodeInfo.NodeInfo   as NodeInfo
import           Network.Tox.Protocol.PacketKind (PacketKind)
import           Network.Tox.Time                (Timestamp (..))
import qualified Network.Tox.Timed               as Timed

import qualified SimulatedDht                    as Sim

main :: IO ()
main =
  Sim.basicSim 10 50 >>= uncurry Sim.runSim >>= mapM_ ((putStrLn =<<) . showPacket)
  where
    showPacket (Sim.SentPacket time from to bytes) = do
      (kind::PacketKind) <- Encoding.decode $ ByteString.take 1 bytes
      return $ showTimestamp time ++ " " ++ showNode from ++ " >>> " ++
        showNode to ++ ": " ++ show kind ++ " " ++
        show (ByteString.length bytes)
    showTimestamp (Timestamp (Clock.TimeSpec secs nsecs)) =
      show $ (fromIntegral secs +
        (fromIntegral $ nsecs `div` 10^(6::Int)) / 1000 :: Float)
    showNode nodeInfo =
      take 8 . drop 1 . show $ NodeInfo.publicKey nodeInfo
