{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE PackageImports         #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TupleSections          #-}

module Thentos.Frontend.Handlers.Combinators where

import Control.Applicative ((<$>))
import Control.Concurrent.MVar (MVar)
import Control.Exception (assert)
import Control.Lens ((^.), (%~), (.~))
import Control.Monad.Except (liftIO)
import Control.Monad.State.Class (gets)
import "crypto-random" Crypto.Random (SystemRNG)
import Data.Acid (AcidState)
import Data.ByteString.Builder (Builder, toLazyByteString)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.String.Conversions (SBS, ST, cs)
import Data.Text.Encoding (encodeUtf8)
import LIO.DCLabel (DCLabel)
import Snap.Blaze (blaze)
import Snap.Core (getResponse, finishWith, urlEncode, getParam)
import Snap.Core (rqURI, getsRequest, redirect', modifyResponse, setResponseStatus)
import Snap.Snaplet.AcidState (getAcidState)
import Snap.Snaplet (Handler, with)
import Snap.Snaplet.Session (commitSession, setInSession, getFromSession)
import System.Log.Missing (logger)
import System.Log (Priority(DEBUG, CRITICAL))
import Text.Digestive.Form (Form)
import Text.Digestive.Snap (runForm)
import Text.Digestive.View (View)
import URI.ByteString (parseURI, parseRelativeRef, laxURIParserOptions, serializeURI, serializeRelativeRef)
import URI.ByteString (URI(..), RelativeRef(..), URIParserOptions, Query(..))

import qualified Data.Aeson as Aeson
import qualified Text.Blaze.Html5 as H

import Thentos.Action
import Thentos.Action.Core
import Thentos.Config
import Thentos.Frontend.Pages
import Thentos.Frontend.Types
import Thentos.Types
import Thentos.Util


-- * dashboard construction

-- | Call 'buildDashboard' to consruct a dashboard page and render it
-- into the application monad.
renderDashboard :: DashboardTab -> (User -> [Role] -> H.Html) -> FH ()
renderDashboard tab pagelet = buildDashboard tab pagelet >>= blaze

-- | Like 'renderDashboard', but take a pagelet builder instead of a
-- pagelet.
renderDashboard' :: DashboardTab -> (User -> [Role] -> H.Html) -> FH ()
renderDashboard' tab pagelet = buildDashboard tab pagelet >>= blaze

-- | Take a dashboard tab and a pagelet, and consruct the dashboard
-- page.
buildDashboard :: DashboardTab -> (User -> [Role] -> H.Html) -> FH H.Html
buildDashboard tab pagelet = buildDashboard' tab (\ u -> return . pagelet u)

-- | Like 'buildDashboard', but take a pagelet builder instead of a
-- pagelet.
buildDashboard' :: DashboardTab -> (User -> [Role] -> FH H.Html) -> FH H.Html
buildDashboard' tab pageletBuilder = do
    runAsUser $ \ _ _ sessionLoginData -> do
        msgs <- popAllFrontendMsgs
        let uid = sessionLoginData ^. fslUserId
        (_, user) <- snapRunAction $ lookupUser uid
        roles     <- snapRunAction $ agentRoles (UserA uid)
        dashboardPagelet msgs roles tab <$> pageletBuilder user roles


-- * form rendering and processing

-- | Take a form action string, a form, a pagelet matching the form
-- and a dashboard tab to render it in, and an action to be performed
-- on the form data once submitted.  Depending on the 'runForm'
-- result, either render the form or process it.  The formAction
-- passed to 'runForm' is the URI of the current request.
runPageletForm :: forall v a .
       Form v FH a
    -> (ST -> View v -> User -> [Role] -> H.Html) -> DashboardTab
    -> (a -> FH ())
    -> FH ()
runPageletForm f pagelet = runPageletForm' f (\ formAction v u -> return . pagelet formAction v u)

-- | Like 'runPageletForm', but takes a page builder instead of a
-- page (this is more for internal use).
runPageletForm' :: forall v a .
       Form v FH a
    -> (ST -> View v -> User -> [Role] -> FH H.Html) -> DashboardTab
    -> (a -> FH ())
    -> FH ()
runPageletForm' f buildPagelet tab = runPageForm' f buildPage
  where
    buildPage :: ST -> View v -> FH H.Html
    buildPage formAction = buildDashboard' tab . buildPagelet formAction

-- | Full-page version of 'runPageletForm'.
runPageForm :: forall v a .
       Form v FH a
    -> (ST -> View v -> H.Html)
    -> (a -> FH ())
    -> FH ()
runPageForm f page = runPageForm' f (\ formAction -> return . page formAction)

-- | Full-page version of 'runPageletForm''.
runPageForm' :: forall v a .
       Form v FH a
    -> (ST -> View v -> FH H.Html)
    -> (a -> FH ())
    -> FH ()
runPageForm' f buildPage a = runHandlerForm f handler a
  where
    handler :: ST -> View v -> FH ()
    handler formAction view = buildPage formAction view >>= blaze

-- | Version of of 'runPageletForm'' that takes a handler rather than
-- a pagelet, and calls that in order to render the empty form.  (For
-- symmetry, the function name should be primed, but there is no
-- non-monadic way to call a handler, so there is only one version of
-- @runHandlerForm@.)
runHandlerForm :: forall v a b .
       Form v FH a
    -> (ST -> View v -> FH b)
    -> (a -> FH b)
    -> FH b
runHandlerForm f handler a = do
    formAction <- cs <$> getsRequest rqURI
    (view, mResult) <- logger DEBUG "[formDriver: runForm]" >> runForm formAction f
    case mResult of
        Nothing -> handler formAction view
        Just result -> logger DEBUG "[formDriver: action]" >> a result


-- * authentication

-- | Call 'runAsUserOrNot', and redirect to login page if not logged
-- in.
runAsUser :: (DCLabel -> FrontendSessionData -> FrontendSessionLoginData -> FH a) -> FH a
runAsUser = (`runAsUserOrNot` redirect' "/user/login" 303)

-- | Runs a given handler with the credentials and the session data of
-- the currently logged-in user.  If not logged in, call a default
-- handler that runs without any special clearance.
-- We don't have to verify that the user matches the session, since both are
-- stored in encrypted in the session cookie, so they cannot be manipulated
-- by the user.
runAsUserOrNot :: (DCLabel -> FrontendSessionData -> FrontendSessionLoginData -> FH a) -> FH a -> FH a
runAsUserOrNot loggedInHandler loggedOutHandler = do
    sessionData :: FrontendSessionData <- getSessionData
    case sessionData ^. fsdLogin of
        Just sessionLoginData -> do
            clearance <- snapRunAction . clearanceByAgent . UserA $ sessionLoginData ^. fslUserId
            loggedInHandler clearance sessionData sessionLoginData
        Nothing -> loggedOutHandler


-- * session management

-- | Extract 'FrontendSessionData' object from cookie.  If n/a, return
-- an empty one.  If a value is stored, but cannot be decoded, crash.
getSessionData :: FH FrontendSessionData
getSessionData = fromMaybe emptyFrontendSessionData
               . (>>= Aeson.decode . cs)
             <$> with sess (getFromSession "ThentosSessionData")

-- | Only store data that doesn't change within a session
-- (e.g. the session token, user id) in the session cookie to avoid
-- race conditions that might lose changes between requests.
--
-- FIXME: move service login state, msg queue from FrontendSessionData
-- to DB.
modifySessionData :: (FrontendSessionData -> (FrontendSessionData, a)) -> FH a
modifySessionData op = do
    sessionData <- getSessionData
    with sess $ do
        let (sessionData', val) = op sessionData
        setInSession "ThentosSessionData" . cs . Aeson.encode $ sessionData'
        commitSession
        return val

-- | A version of 'modifySessionData' without return value.
modifySessionData' :: (FrontendSessionData -> FrontendSessionData) -> FH ()
modifySessionData' f = modifySessionData $ (, ()) . f

-- | Construct the service login state (extract service id from
-- params, callback is passed as argument; crash if argument is
-- Nothing).  Write it to the snap session and return it.
setServiceLoginState :: FH ServiceLoginState
setServiceLoginState = do
    sid <- getParam "sid" >>= maybe
             (crash 400 "Service login: missing Service ID.")
             (return . ServiceId . cs)
    rrf <- getsRequest rqURI >>= \ callbackSBS -> either
             (\ msg -> crash 400 $ "Service login: malformed redirect URI: " <> cs (show (msg, callbackSBS)))
             (return)
             (parseRelativeRef laxURIParserOptions callbackSBS)

    let val = ServiceLoginState sid rrf
    modifySessionData' $ fsdServiceLoginState .~ Just val
    logger DEBUG ("setServiceLoginState: set to " <> show val)
    return val

-- | Recover the service login state from snap session, remove it
-- there, and return it.  If no service login state is stored, return
-- 'Nothing'.
popServiceLoginState :: FH (Maybe ServiceLoginState)
popServiceLoginState = modifySessionData $
    \ fsd -> (fsdServiceLoginState .~ Nothing $ fsd, fsd ^. fsdServiceLoginState)

-- | Recover the service login state from snap session like
-- 'popServiceLoginState', but do not remove it.
getServiceLoginState :: FH (Maybe ServiceLoginState)
getServiceLoginState = modifySessionData $ \ fsd -> (fsd, fsd ^. fsdServiceLoginState)

sendFrontendMsgs :: [FrontendMsg] -> FH ()
sendFrontendMsgs msgs = modifySessionData' $ fsdMessages %~ (++ msgs)

sendFrontendMsg :: FrontendMsg -> FH ()
sendFrontendMsg = sendFrontendMsgs . (:[])

popAllFrontendMsgs :: FH [FrontendMsg]
popAllFrontendMsgs = modifySessionData $ \ fsd -> (fsdMessages .~ [] $ fsd, fsd ^. fsdMessages)


-- * error handling

crash' :: (Show a) => Int -> a -> SBS -> Handler b v x
crash' status logMsg usrMsg = do
    logger DEBUG $ show (status, logMsg, usrMsg)
    modifyResponse $ setResponseStatus status usrMsg
    blaze . errorPage . cs $ usrMsg
    getResponse >>= finishWith

crash :: Int -> SBS -> Handler b v x
crash status usrMsg = crash' status () usrMsg

-- | Use this for internal errors.  Ideally, we shouldn't have to even
-- write those, but structure the code in a way that makes places
-- where this is called syntactially unreachable.  Oh well.
crash500 :: (Show a) => a -> Handler b v x
crash500 a = do
    logger CRITICAL $ show ("*** internal error: " <> show a)
    crash 500 "internal error.  we are very sorry."

urlConfirm :: HttpConfig -> ST -> ST -> ST
urlConfirm feConfig path token = exposeUrl feConfig <//> toST ref
  where
    ref   = RelativeRef Nothing (cs path) (Query query) Nothing
    query = [("token", urlEncode . encodeUtf8 $ token)]
    toST  = cs . toLazyByteString . serializeRelativeRef


-- * uri manipulation

redirectURI :: URI -> FH ()
redirectURI ref = redirect' (cs . toLazyByteString . serializeURI $ ref) 303

redirectRR :: RelativeRef -> FH ()
redirectRR ref = redirect' (cs . toLazyByteString . serializeRelativeRef $ ref) 303


tweakRelativeRqRef :: (RelativeRef -> RelativeRef) -> FH SBS
tweakRelativeRqRef tweak = getsRequest rqURI >>= tweakRelativeRef tweak

tweakRelativeRef :: (RelativeRef -> RelativeRef) -> SBS -> FH SBS
tweakRelativeRef = _tweakURI parseRelativeRef serializeRelativeRef

tweakURI :: (URI -> URI) -> SBS -> FH SBS
tweakURI = _tweakURI parseURI serializeURI

_tweakURI :: forall e t t' . (Show e) =>
                   (URIParserOptions -> SBS -> Either e t)
                -> (t' -> Builder)
                -> (t -> t')
                -> SBS
                -> FH SBS
_tweakURI parse serialize tweak uriBS = either er ok $ parse laxURIParserOptions uriBS
  where
    ok = return . cs . toLazyByteString . serialize . tweak
    er = crash500 . ("_tweakURI" :: ST, uriBS,)


-- * actions vs. snap

-- | Like 'snapRunActionE', but sends a snap error response in case of error rather than returning a
-- left value.
snapRunAction :: Action DB a -> FH a
snapRunAction action = snapRunActionE action >>= \case
    Right v -> return v
    Left e  -> snapHandleError e

-- | This function could, e.g., handle redirect to login page in case of permission denied.  For now
-- it just crashes every time.
snapHandleError :: ActionError -> FH a
snapHandleError = crash500

-- | Read the clearance from the 'App' state and apply it to 'runAction'.
snapRunActionE :: Action DB a -> FH (Either ActionError a)
snapRunActionE action = do
    st :: AcidState DB   <- getAcidState
    rn :: MVar SystemRNG <- gets (^. rng)
    cf :: ThentosConfig  <- gets (^. cfg)

    clearance :: DCLabel <- assert False $ error "snapRunAction: need to stick clearance into state"
    liftIO $ runActionE clearance (ActionState (st, rn, cf)) action
