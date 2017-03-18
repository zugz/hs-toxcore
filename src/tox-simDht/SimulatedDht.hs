{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE Trustworthy                #-}

-- | simulated DHT network with many nodes, with no IO.
module SimulatedDht where

import           Control.Applicative                    (Applicative, (<$>),
                                                         (<*>))
import           Control.Monad                          (forM, forM_, guard,
                                                         replicateM, unless,
                                                         void, when)
import           Control.Monad.Random                   (RandT, evalRandT)
import           Control.Monad.Reader                   (ReaderT, ask,
                                                         runReaderT)
import           Control.Monad.RWS                      (MonadReader,
                                                         MonadState, RWST,
                                                         execRWST, local, state)
import           Control.Monad.State                    (State, StateT,
                                                         evalState, execStateT,
                                                         gets, modify)
import           Control.Monad.Trans.Class              (lift)
import           Control.Monad.Trans.Maybe              (MaybeT (..), runMaybeT)
import           Control.Monad.Writer                   (MonadWriter, WriterT,
                                                         runWriterT, tell)
import           Data.ByteString                        (ByteString)
import qualified Data.ByteString                        as ByteString
import           Data.Foldable                          (for_)
import           Data.List                              ((\\))
import qualified Data.List                              as List
import           Data.Map                               (Map)
import qualified Data.Map                               as Map
import           System.Random                          (StdGen, getStdGen)

import           Network.Tox.Crypto.Key                 (PublicKey)
import           Network.Tox.Crypto.Keyed               (Keyed)
import           Network.Tox.Crypto.KeyedT              (KeyedT)
import qualified Network.Tox.Crypto.KeyedT              as KeyedT
import           Network.Tox.Crypto.KeyPair             (KeyPair)
import qualified Network.Tox.Crypto.KeyPair             as KeyPair
import qualified Network.Tox.DHT.DhtPacket              as DhtPacket
import           Network.Tox.DHT.DhtRequestPacket       (DhtRequestPacket (..))
import           Network.Tox.DHT.DhtState               (DhtState)
import qualified Network.Tox.DHT.DhtState               as DhtState
import qualified Network.Tox.DHT.Operation              as DhtOperation
import qualified Network.Tox.DHT.Stamped                as Stamped
import qualified Network.Tox.Encoding                   as Encoding
import           Network.Tox.Network.MonadRandomBytes   (MonadRandomBytes)
import qualified Network.Tox.Network.MonadRandomBytes   as MonadRandomBytes
import           Network.Tox.Network.Networked          (Networked (..))
import           Network.Tox.NodeInfo.HostAddress       (HostAddress (..))
import           Network.Tox.NodeInfo.NodeInfo          (NodeInfo (..))
import           Network.Tox.NodeInfo.PortNumber        (PortNumber (..))
import           Network.Tox.NodeInfo.SocketAddress     (SocketAddress (..))
import           Network.Tox.NodeInfo.TransportProtocol (TransportProtocol (..))
import           Network.Tox.Protocol.Packet            (Packet (..))
import qualified Network.Tox.Protocol.PacketKind        as PacketKind
import           Network.Tox.Time                       (TimeDiff, Timestamp)
import qualified Network.Tox.Time                       as Time
import           Network.Tox.Timed                      (Timed, askTime)
import qualified Network.Tox.TimedT                     as TimedT

import           Event                                  (Event)
import qualified Event

type SimulatedDht = Map NodeInfo DhtState

data SentPacket = SentPacket
  { sentTime :: Timestamp
  , sentFrom :: NodeInfo
  , sentTo   :: NodeInfo
  , sentData :: ByteString
  }
  deriving (Eq, Ord, Show)

type Traffic = [SentPacket]

type SimDhtMonad = KeyedT (RandT StdGen (WriterT Traffic (State SimulatedDht)))

type SimDhtEvent = Event SimDhtMonad

type SimDhtEventStream = Event.EventStream SimDhtMonad

newtype SimDhtNodeMonad a = SimDhtNodeMonad (RWST NodeInfo [SentPacket] DhtState SimDhtEvent a)
  deriving (Monad, Functor, Applicative, MonadRandomBytes, Timed, Keyed
    , MonadReader NodeInfo, MonadWriter Traffic, MonadState DhtState)

askCurrentNode :: SimDhtNodeMonad NodeInfo
askCurrentNode = ask

atNode :: NodeInfo -> SimDhtNodeMonad () -> SimDhtEvent ()
atNode node (SimDhtNodeMonad m) = void . runMaybeT $ do
  dhtState <- MaybeT . gets $ Map.lookup node
  lift $ do
    dhtState' <- fst <$> execRWST m node dhtState
    modify $ Map.insert node dhtState'

liftToNode :: SimDhtEvent a -> SimDhtNodeMonad a
liftToNode = SimDhtNodeMonad . lift

instance Networked SimDhtNodeMonad where
  sendPacket to packet = askCurrentNode >>= \us -> liftToNode $ do
      time <- askTime
      packetLost <- randomUDPLoss us to
      delay <- randomUDPDelay us to
      unless packetLost $ do
        let encoded = Encoding.encode packet
        tell [SentPacket time us to encoded]
        Event.schedule delay . atNode to $ handlePacket us encoded

instance DhtOperation.DhtNodeMonad SimDhtNodeMonad

-- | TODO - something more realistic
randomUDPLoss :: NodeInfo -> NodeInfo -> SimDhtEvent Bool
randomUDPLoss _ _ = (== 1) <$> MonadRandomBytes.randomIntR (1,100)

-- | TODO - something more realistic
randomUDPDelay :: NodeInfo -> NodeInfo -> SimDhtEvent TimeDiff
randomUDPDelay _ _ = Time.milliseconds . fromIntegral <$> MonadRandomBytes.randomIntR (100,500)

getKeyPair :: SimDhtNodeMonad KeyPair
getKeyPair = gets DhtState.dhtKeyPair

handlePacket :: NodeInfo -> ByteString -> SimDhtNodeMonad ()
handlePacket from bytes =
  let (kindByte, payload) = ByteString.splitAt 1 bytes
  in void . runMaybeT $ do
    kind <- Encoding.decode kindByte
    keyPair <- lift getKeyPair
    case kind of
      PacketKind.Crypto ->
        Encoding.decode payload >>=
          lift . DhtOperation.handleDhtRequestPacket from
      PacketKind.PingRequest ->
        Encoding.decode payload >>=
          MaybeT . DhtPacket.decodeKeyed keyPair >>=
          lift . DhtOperation.handlePingRequest from
      PacketKind.PingResponse ->
        Encoding.decode payload >>=
          MaybeT . DhtPacket.decodeKeyed keyPair >>=
          lift . DhtOperation.handlePingResponse from
      PacketKind.NodesRequest ->
        Encoding.decode payload >>=
          MaybeT . DhtPacket.decodeKeyed keyPair >>=
          lift . DhtOperation.handleNodesRequest from
      PacketKind.NodesResponse ->
        Encoding.decode payload >>=
          MaybeT . DhtPacket.decodeKeyed keyPair >>=
          lift . DhtOperation.handleNodesResponse from
      _ -> error "unhandled packet"

basicSim :: Int -> Int -> IO (SimulatedDht, SimDhtEventStream)
basicSim numBootstrap numNormal = do
  let time = Time.Timestamp 0
  dhtStates <- (`TimedT.runTimedT` time) $
    replicateM (numBootstrap + numNormal) DhtOperation.initDHT
  initDhtAssocs <- forM dhtStates $ \dhtState ->
    (flip (,) dhtState <$>) .
      randomNode . KeyPair.publicKey . DhtState.dhtKeyPair $ dhtState
  let
    nodes = fst <$> initDhtAssocs
    (bootstrapNodes, normalNodes) = splitAt numBootstrap nodes
    baseDht = Map.fromList initDhtAssocs
    -- |bootstrap nodes start knowing each other
    initDht = foldr
      (\(node,node') -> Map.adjust (DhtState.addNode time node') node)
      baseDht
      [ (node,node')
        | node <- bootstrapNodes
        , node' <- bootstrapNodes
        , node /= node'
        ]
    initEventStream = foldr (Stamped.add time) Stamped.empty $
        [ atNode node $ DhtOperation.bootstrapNode bootstrap
          | node <- normalNodes
          , bootstrap <- bootstrapNodes
          ]
        ++ [ doDHTForever node | node <- nodes ]
  return (initDht, initEventStream)
  where
    randomNode :: PublicKey -> IO NodeInfo
    randomNode pub =
        NodeInfo UDP
          <$> (SocketAddress
            <$> (IPv4 <$> MonadRandomBytes.randomWord32)
            <*> (PortNumber <$> MonadRandomBytes.randomWord16))
          <*> return pub
    doDHTForever node = do
      atNode node DhtOperation.doDHT
      Event.schedule (Time.milliseconds 50) $ doDHTForever node

runSim :: SimulatedDht -> SimDhtEventStream -> IO Traffic
runSim initDht initEventStream = do
  gen <- getStdGen
  return $ snd . (`evalState` initDht)
    . runWriterT
    . (`evalRandT` gen)
    . (`KeyedT.evalKeyedT` Map.empty)
    . Event.runStream $ initEventStream

superviseSim :: SimulatedDht -> SimDhtEventStream -> IO ()
superviseSim _ _ =
  -- TODO
  return ()
