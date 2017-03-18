{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE Trustworthy                #-}
{-# LANGUAGE UndecidableInstances       #-}

module Event where


import           Control.Applicative                  (Applicative)
import           Control.Monad                        (forever, void)
import           Control.Monad.Reader                 (MonadReader, ReaderT,
                                                       ReaderT (..), ask, local,
                                                       mapReaderT, runReaderT)
import           Control.Monad.State                  (MonadState, StateT,
                                                       modify, runStateT, state)
import           Control.Monad.Trans.Class            (lift)
import           Control.Monad.Trans.Maybe            (MaybeT (..), runMaybeT)
import           Control.Monad.Writer                 (MonadWriter, WriterT,
                                                       WriterT (..),
                                                       execWriterT, listen,
                                                       mapWriterT, pass,
                                                       runWriterT, tell)

import           Network.Tox.Crypto.Keyed             (Keyed)
import           Network.Tox.DHT.Stamped              (Stamped)
import qualified Network.Tox.DHT.Stamped              as Stamped
import           Network.Tox.Network.MonadRandomBytes (MonadRandomBytes)
import           Network.Tox.Time                     (TimeDiff, Timestamp)
import qualified Network.Tox.Time                     as Time
import           Network.Tox.Timed                    (Timed, adjustTime,
                                                       askTime)

-- | an 'Event m a' is an event of a monadic action m a, which can occur at a
-- time (and the time of occurance is made available to the action), and can
-- schedule further events (for the same monad m) to occur later.
newtype Event m a = Event (WriterT [(TimeDiff, Event m ())] (ReaderT Timestamp m) a)
  deriving (Monad, Functor, Applicative, MonadState s, MonadRandomBytes, Keyed)

instance MonadWriter w m => MonadWriter w (Event m) where
  tell = Event . lift . tell
  listen (Event m) = Event . WriterT . ReaderT $ \r -> do
    ((a,w),w') <- listen . (`runReaderT` r) $ runWriterT m
    return ((a,w'),w)
  pass (Event m) = Event . WriterT . ReaderT $ \r -> pass $ do
    ((a,f),w') <- (`runReaderT` r) $ runWriterT m
    return ((a,w'),f)

instance Monad m => Timed (Event m) where
  askTime = Event ask
  adjustTime f (Event m) = Event $ local f m

schedule :: Monad m => TimeDiff -> Event m () -> Event m ()
schedule delay event = Event $ tell [(delay, event)]


-- | a time-ordered sequence of scheduled events
type EventStream m = Stamped (Event m ())

-- | performs and removes the first event, adding any events it schedules
stepEventStream :: (Monad m, Functor m) => StateT (EventStream m) m ()
stepEventStream = void . runMaybeT $ do
  (time, Event event) <- MaybeT $ state Stamped.popFirst
  lift $ (lift . (`runReaderT` time) . execWriterT $ event) >>=
    modify . flip (foldr $ \(delay, newEvent) -> Stamped.add (time Time.+ delay) newEvent)

runStream :: (Monad m, Functor m) => EventStream m -> m ()
runStream = void . runStateT (forever stepEventStream)

