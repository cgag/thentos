{-# LANGUAGE ExistentialQuantification                #-}
{-# LANGUAGE FlexibleContexts                         #-}
{-# LANGUAGE FlexibleInstances                        #-}
{-# LANGUAGE GADTs                                    #-}
{-# LANGUAGE InstanceSigs                             #-}
{-# LANGUAGE MultiParamTypeClasses                    #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE RankNTypes                               #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TupleSections                            #-}
{-# LANGUAGE TypeSynonymInstances                     #-}
{-# LANGUAGE ViewPatterns                             #-}

module ThentosSpec where

import Control.Lens ((.~))
import Control.Monad (void)
import Data.Acid.Advanced (query', update')
import Data.Either (isLeft, isRight)
import Test.Hspec (Spec, hspec, describe, it, before, after, shouldBe, shouldSatisfy)

import Thentos.Api
import Thentos.DB
import Thentos.Types

import Test.Config
import Test.Util


tests :: IO ()
tests = hspec spec

spec :: Spec
spec = do
  describe "DB" . before (setupDB testThentosConfig) . after teardownDB $ do
    describe "hspec meta" $ do
      it "`setupDB, teardownDB` are called once for every `it` here (part I)." $ \ (st, _, _) -> do
        Right _ <- update' st $ AddUser user3 allowEverything
        True `shouldBe` True

      it "`setupDB, teardownDB` are called once for every `it` here (part II)." $ \ (st, _, _) -> do
        uids <- query' st $ AllUserIds allowEverything
        uids `shouldSatisfy` \ (Right [UserId 0, UserId 1, UserId 2]) -> True  -- (no (UserId 2))

    describe "AddUser, LookupUser, DeleteUser" $ do
      it "works" $ \ (st, _, _) -> do
        Right uid <- update' st $ AddUser user3 allowEverything
        Right (uid', user3') <- query' st $ LookupUser uid allowEverything
        user3' `shouldBe` user3
        uid' `shouldBe` uid
        void . update' st $ DeleteUser uid allowEverything
        u <- query' st $ LookupUser uid allowEverything
        u `shouldSatisfy` \ (Left (fromThentosError -> Just NoSuchUser)) -> True

      it "guarantee that user names are unique" $ \ (st, _, _) -> do
        result <- update' st $ AddUser (userEmail .~ (UserEmail "new@one.com") $ user1) allowEverything
        result `shouldSatisfy` \ (Left (fromThentosError -> Just UserNameAlreadyExists)) -> True

      it "guarantee that user email addresses are unique" $ \ (st, _, _) -> do
        result <- update' st $ AddUser (userName .~ (UserName "newone") $ user1) allowEverything
        result `shouldSatisfy` \ (Left (fromThentosError -> Just UserEmailAlreadyExists)) -> True

    describe "DeleteUser" $ do
      it "user can delete herself, even if not admin" $ \ (st, _, _) -> do
        let uid = UserId 1
        result <- update' st $ DeleteUser uid (UserA uid *%% UserA uid)
        result `shouldSatisfy` isRight

      it "nobody else but the deleted user and admin can do this" $ \ (st, _, _) -> do
        result <- update' st $ DeleteUser (UserId 1) (UserA (UserId 2) *%% UserA (UserId 2))
        result `shouldSatisfy` isLeft

    describe "UpdateUser" $ do
      it "changes user if it exists" $ \ (st, _, _) -> do
        result <- update' st $ UpdateUser (UserId 1) user1 allowEverything
        result `shouldSatisfy` isRight
        result2 <- query' st $ LookupUser (UserId 1) allowEverything
        result2 `shouldSatisfy` \ (Right (UserId 1, _)) -> True

      it "throws an error if user does not exist" $ \ (st, _, _) -> do
        result <- update' st $ UpdateUser (UserId 391) user3 allowEverything
        result `shouldSatisfy` \ (Left (fromThentosError -> Just NoSuchUser)) -> True

    describe "AddUsers" $ do
      it "works" $ \ (st, _, _) -> do
        result <- update' st $ AddUsers [user3, user4, user5] allowEverything
        result `shouldSatisfy` \ (Right [UserId 3, UserId 4, UserId 5]) -> True

      it "rolls back in case of error (adds all or nothing)" $ \ (st, _, _) -> do
        result0 <- update' st $ AddUsers [user4, user3, user3] allowEverything
        result0 `shouldSatisfy` \ (Left (fromThentosError -> Just UserEmailAlreadyExists)) -> True
        result <- query' st $ AllUserIds allowEverything
        result `shouldSatisfy` \ (Right [UserId 0, UserId 1, UserId 2]) -> True

    describe "AddService, LookupService, DeleteService" $ do
      it "works" $ \ asg@(st, _, _) -> do
        Right (service1_id, _s1_key) <- runAction' (asg, allowEverything) $ addService "fake name" "fake description"
        Right (service2_id, _s2_key) <- runAction' (asg, allowEverything) $ addService "different name" "different description"
        Right service1 <- query' st $ LookupService service1_id allowEverything
        Right service2 <- query' st $ LookupService service2_id allowEverything
        service1 `shouldBe` service1 -- sanity check for reflexivity of Eq
        service1 `shouldSatisfy` (/= service2) -- should have different keys
        void . update' st $ DeleteService service1_id allowEverything
        result <- query' st $ LookupService service1_id allowEverything
        result `shouldSatisfy` \ (Left (fromThentosError -> Just NoSuchService)) -> True
        return ()

    describe "StartSession" $ do
      it "works" $ \ asg -> do
        result <- runAction' (asg, allowEverything) $ startSessionNoPass (UserA $ UserId 0)
        result `shouldSatisfy` isRight
        return ()

    describe "agents and roles" $ do
      describe "assign" $ do
        it "can be called by admins" $ \ (st, _, _) -> do
          let targetAgent = UserA $ UserId 1
          result <- update' st $ AssignRole targetAgent RoleAdmin (RoleAdmin *%% RoleAdmin)
          result `shouldSatisfy` isRight

        it "can NOT be called by any non-admin agents" $ \ (st, _, _) -> do
          let targetAgent = UserA $ UserId 1
          result <- update' st $ AssignRole targetAgent RoleAdmin (targetAgent *%% targetAgent)
          result `shouldSatisfy` isLeft

      describe "lookup" $ do
        it "can be called by admins" $ \ (st, _, _) -> do
          let targetAgent = UserA $ UserId 1
          result :: Either SomeThentosError [Role] <- query' st $ LookupAgentRoles targetAgent (RoleAdmin *%% RoleAdmin)
          result `shouldSatisfy` isRight

        it "can be called by user for her own roles" $ \ (st, _, _) -> do
          let targetAgent = UserA $ UserId 1
          result <- query' st $ LookupAgentRoles targetAgent (targetAgent *%% targetAgent)
          result `shouldSatisfy` isRight

        it "can NOT be called by other users" $ \ (st, _, _) -> do
          let targetAgent = UserA $ UserId 1
              askingAgent = UserA $ UserId 2
          result <- query' st $ LookupAgentRoles targetAgent (askingAgent *%% askingAgent)
          result `shouldSatisfy` isLeft
