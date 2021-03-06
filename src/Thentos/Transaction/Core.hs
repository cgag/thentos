{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE ViewPatterns         #-}

module Thentos.Transaction.Core
  ( ThentosUpdate, ThentosUpdate'
  , ThentosQuery, ThentosQuery'
  , liftThentosQuery
  , runThentosUpdate
  , runThentosQuery
  ) where

import Control.Applicative ((<$>))
import Control.Monad.Identity (Identity, runIdentity)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.State (StateT(StateT), runStateT, get, put)
import Control.Monad.Trans.Either (EitherT(EitherT), runEitherT)
import Data.Acid (Update, Query)

import Thentos.Types


-- * types

type ThentosUpdate db a = ThentosUpdate' db ThentosError a
type ThentosQuery  db a = ThentosQuery'  db ThentosError a

type ThentosUpdate' db e a = EitherT e (StateT  db Identity) a
type ThentosQuery'  db e a = EitherT e (ReaderT db Identity) a

-- FUTURE WORK: make primed types newtypes rather than type synonyms, and provide a generic monad
-- instance.  (how does that work?)


-- * plumbing

-- | 'liftQuery' for 'ThentosUpdate' and 'ThentosUpdate''.
liftThentosQuery :: ThentosQuery' db e a -> ThentosUpdate' db e a
liftThentosQuery thentosQuery = EitherT . StateT $ \ state ->
    (, state) <$> runEitherT thentosQuery `runReaderT` state

-- | Push 'ThentosUpdate' event down to acid-state's own 'Update'.  Errors are returned as 'Left'
-- values in an 'Either'.  See also:
--
-- - http://www.reddit.com/r/haskell/comments/2re0da/error_handling_in_acidstate/
-- - http://petterbergman.se/aciderror.html.en
-- - http://acid-state.seize.it/Error%20Scenarios
-- - https://github.com/acid-state/acid-state/pull/38
runThentosUpdate :: ThentosUpdate DB a -> Update DB (Either ThentosError a)
runThentosUpdate action = do
    state <- get
    case runIdentity $ runStateT (runEitherT action) state of
        (Left err,     _)      ->               (return $ Left err)
        (Right result, state') -> put state' >> (return $ Right result)


-- | 'runThentosUpdate' for 'ThentosQuery' and 'ThentosQuery''
runThentosQuery :: ThentosQuery DB a -> Query DB (Either ThentosError a)
runThentosQuery action = runIdentity . runReaderT (runEitherT action) <$> ask
