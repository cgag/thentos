{-# LANGUAGE OverloadedStrings #-}

module Test.Config
where

import Data.Acid (AcidState)
import Data.Configifier ((:*>)((:*>)), Id(Id), Tagged(Tagged), MaybeO(JustO, NothingO), fromTagged)

import Thentos.Types
import Thentos.Config
import Thentos (createDefaultUser)


data TestConfig =
    TestConfig
      { dbPath :: FilePath
      , restPort :: Int
      , serverFullBackendPort :: Int
      , serverFullFrontendPort :: Int
      , webdriverHost :: String
      , webdriverPort :: Int
      }
  deriving (Eq, Show)

testConfig :: TestConfig
testConfig =
    TestConfig
      { dbPath = ".test-db/"
      , restPort = 8002
      , serverFullBackendPort = 7118
      , serverFullFrontendPort = 7119
      , webdriverHost = "localhost"
      , webdriverPort = 4451
      }

testThentosConfig :: ThentosConfig
testThentosConfig = Tagged $
      Id Run
  :*> JustO (Id (fromTagged testFeConfig))
  :*> JustO (Id (fromTagged testBeConfig))
  :*> NothingO
  :*> Id (fromTagged testSmtpConfig)
  :*> NothingO
  :*> Id (Timeout 3600)
  :*> Id (Timeout 3600)
  :*> Id (Timeout 3600)
  :*> JustO (Id 1800)

testFeConfig :: HttpConfig
testFeConfig = Tagged $
      NothingO
  :*> Id "localhost"
  :*> Id (serverFullFrontendPort testConfig)
  :*> NothingO
  :*> NothingO
  :*> NothingO

testBeConfig :: HttpConfig
testBeConfig = Tagged $
      NothingO
  :*> Id "localhost"
  :*> Id (serverFullBackendPort testConfig)
  :*> NothingO
  :*> NothingO
  :*> NothingO

testSmtpConfig :: SmtpConfig
testSmtpConfig = Tagged $
      JustO (Id "Thentos")
  :*> Id "thentos@thentos.org"
  :*> Id "/bin/cat"  -- FIXME: /bin/cat pollutes stdout.
  :*> Id []

godUid :: UserId
godUid = UserId 0

godName :: UserName
godName = "god"

godPass :: UserPass
godPass = "god"

createGod :: AcidState DB -> IO ()
createGod st = createDefaultUser st
    (Just . Tagged $
          Id (fromUserName godName)
      :*> Id (fromUserPass godPass)
      :*> Id "postmaster@localhost"
      :*> JustO (Id [RoleAdmin]) :: Maybe DefaultUserConfig)
