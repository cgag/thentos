{-# LANGUAGE DataKinds                                #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TypeFamilies                             #-}
{-# LANGUAGE TypeOperators                            #-}

{-# OPTIONS  #-}

module DB.Protect
  ( mkThentosClearance
  , allowEverything
  , allowNothing
  , godCredentials
  , createGod
  ) where

import Control.Lens ((^.))
import Control.Monad (when)
import Data.List (foldl')
import Data.Acid (AcidState)
import Data.Acid.Advanced (query', update')
import Data.Either (isLeft, isRight)
import Data.String.Conversions (ST)
import LIO.DCLabel (CNF, toCNF, dcPublic, (%%), (/\), (\/))
import Network.HTTP.Types.Header (Header)

import DB.Api
import DB.Core
import Types


-- | If password cannot be verified, or if only password or only
-- principal is provided, throw an error explaining the problem.  If
-- none are provided, set clearance level to 'allowNothing'.  If both
-- are provided, look up roles of principal, and set clearance level
-- to that of the principal aka agent and all its roles.
--
-- Note: Both 'Role's and 'Agent's can be used in authorization
-- policies.  ('User' can be used, but it must be wrapped into an
-- 'UserA'.)
mkThentosClearance :: Maybe ST -> Maybe ST -> Maybe ST -> DB -> Either DbError ThentosClearance
mkThentosClearance (Just user) Nothing        (Just password) db = authenticateUser db (UserName user) (UserPass password)
mkThentosClearance Nothing     (Just service) (Just password) db = authenticateService db (ServiceId service) (ServiceKey password)
mkThentosClearance Nothing     Nothing        Nothing         _  = Right allowNothing
mkThentosClearance _           _              _               _  = Left BadAuthenticationHeaders


authenticateUser :: DB -> UserName -> UserPass -> Either DbError ThentosClearance
authenticateUser db name password = do
    (uid, user) :: (UserId, User)
        <- maybe (Left BadCredentials) (Right) $ pure_lookupUserByName db name

    credentials :: [CNF]
        <- let a = UserA uid
           in Right $ toCNF a : map toCNF (pure_lookupAgentRoles db a)

    if user ^. userPassword /= password
        then Left BadCredentials
        else Right $ simpleClearance credentials


authenticateService :: DB -> ServiceId -> ServiceKey -> Either DbError ThentosClearance
authenticateService db sid keyFromClient = do
    Service keyFromDb
        <- maybe (Left BadCredentials) (Right) $ pure_lookupService db sid

    credentials :: [CNF]
        <- let a = ServiceA sid
           in Right $ toCNF a : map toCNF (pure_lookupAgentRoles db a)

    if keyFromClient /= keyFromDb
        then Left BadCredentials
        else Right $ simpleClearance credentials


simpleClearance :: [CNF] -> ThentosClearance
simpleClearance credentials = case credentials of
    []     -> allowNothing
    (x:xs) -> ThentosClearance $ foldl' (/\) x xs %% foldl' (\/) x xs


-- | FIXME: move this to Core and implement it!
pure_lookupService :: DB -> ServiceId -> Maybe Service
pure_lookupService _ _ = Nothing

-- | FIXME: move this to Core and implement it!
pure_lookupAgentRoles :: DB -> Agent -> [Role]
pure_lookupAgentRoles _ _  = []


allowEverything :: ThentosClearance
allowEverything = ThentosClearance dcPublic

allowNothing :: ThentosClearance
allowNothing = ThentosClearance (False %% False)


godCredentials :: [Header]
godCredentials = [("X-Thentos-User", "god"), ("X-Thentos-Password", "god")]

createGod :: AcidState DB -> Bool -> IO ()
createGod st verbose = do
    eq <- query' st (LookupUser (UserId 0) allowEverything)
    when (isLeft eq) $ do
        when verbose $
            putStr "No users.  Creating god user with password 'god'... "
        eu <- update' st (AddUser (User "god" "god" "god@home" [] []) allowEverything)
        when verbose $
            if isRight eu
                then putStrLn "[ok]"
                else putStrLn $ "[failed: " ++ show eu ++ "]"
