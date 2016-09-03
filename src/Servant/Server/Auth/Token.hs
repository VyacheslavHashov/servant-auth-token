{-# OPTIONS_GHC -fno-warn-orphans #-}
{-|
Module      : Servant.Server.Auth.Token
Description : Implementation of token authorisation API
Copyright   : (c) Anton Gushcha, 2016
License     : MIT
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : Portable

The module is server side implementation of "Servant.API.Auth.Token" API and intended to be
used as drop in module for user servers or as external micro service.

To use the server as constituent part, you need to provide customised 'AuthConfig' for 
'authServer' function and implement 'AuthMonad' instance for your handler monad.

@
import Servant.Server.Auth.Token as Auth

-- | Example of user side configuration
data Config = Config {
  -- | Authorisation specific configuration
  authConfig :: AuthConfig
  -- other fields
  -- ...
}

-- | Example of user side handler monad
newtype App a = App { 
    runApp :: ReaderT Config (ExceptT ServantErr IO) a
  } deriving ( Functor, Applicative, Monad, MonadReader Config,
               MonadError ServantErr, MonadIO)

-- | Now you can use authorisation API in your handler
instance AuthMonad App where 
  getAuthConfig = asks authConfig
  liftAuthAction = App . lift

-- | Include auth 'migrateAll' function into your migration code
doMigrations :: SqlPersistT IO ()
doMigrations = runMigrationUnsafe $ do 
  migrateAll -- other user migrations
  Auth.migrateAll -- creation of authorisation entities
  -- optional creation of default admin if db is empty
  ensureAdmin 17 "admin" "123456" "admin@localhost" 
@

Now you can use 'guardAuthToken' to check authorisation headers in endpoints of your server:

@
-- | Read a single customer from DB
customerGet :: CustomerId -- ^ Customer unique id
  -> MToken' '["customer-read"] -- ^ Required permissions for auth token
  -> App Customer -- ^ Customer data
customerGet i token = do
  guardAuthToken token 
  runDB404 "customer" $ getCustomer i 
@

-}
module Servant.Server.Auth.Token(
  -- * Implementation
    authServer
  -- * Server API
  , migrateAll
  , AuthMonad(..)
  -- * Helpers
  , guardAuthToken 
  , ensureAdmin
  , authUserByToken
  -- * API methods
  , authSignin
  , authSigninGetCode
  , authSigninPostCode
  , authTouch
  , authToken
  , authSignout
  , authSignup
  , authUsersInfo
  , authUserInfo
  , authUserPatch
  , authUserPut
  , authUserDelete
  , authRestore
  , authGroupGet
  , authGroupPost
  , authGroupPut
  , authGroupPatch
  , authGroupDelete
  , authGroupList
  -- * Low-level API
  , getAuthToken
  ) where 

import Control.Monad 
import Control.Monad.Except 
import Control.Monad.Reader
import Crypto.PasswordStore
import Data.Aeson.Unit
import Data.Aeson.WithField
import Data.Maybe
import Data.Monoid
import Data.Text.Encoding
import Data.Time.Clock
import Data.UUID
import Data.UUID.V4
import Database.Persist.Postgresql
import Servant 

import Servant.API.Auth.Token
import Servant.API.Auth.Token.Pagination
import Servant.Server.Auth.Token.Common
import Servant.Server.Auth.Token.Config
import Servant.Server.Auth.Token.Model
import Servant.Server.Auth.Token.Monad
import Servant.Server.Auth.Token.Pagination
import Servant.Server.Auth.Token.Restore
import Servant.Server.Auth.Token.SingleUse

import qualified Data.ByteString.Lazy as BS 

-- | This function converts our 'AuthHandler' monad into the @ExceptT ServantErr
-- IO@ monad that Servant's 'enter' function needs in order to run the
-- application. The ':~>' type is a natural transformation, or, in
-- non-category theory terms, a function that converts two type
-- constructors without looking at the values in the types.
convertAuthHandler :: AuthConfig -> AuthHandler :~> ExceptT ServantErr IO
convertAuthHandler cfg = Nat (flip runReaderT cfg . runAuthHandler)

-- | The interface your application should implement to be able to use
-- token authorisation API.
class Monad m => AuthMonad m where 
  getAuthConfig :: m AuthConfig 
  liftAuthAction :: ExceptT ServantErr IO a -> m a 

instance AuthMonad AuthHandler where 
  getAuthConfig = getConfig 
  liftAuthAction = AuthHandler . lift 
  
-- | Helper to run handler in 'AuthMonad' context
runAuth :: AuthMonad m => AuthHandler a -> m a
runAuth m = do 
  cfg <- getAuthConfig
  let Nat conv = convertAuthHandler cfg 
  liftAuthAction $ conv m 

-- | Implementation of AuthAPI
authServer :: AuthConfig -> Server AuthAPI
authServer cfg = enter (convertAuthHandler cfg) (
       authSignin
  :<|> authSigninGetCode
  :<|> authSigninPostCode
  :<|> authTouch
  :<|> authToken 
  :<|> authSignout
  :<|> authSignup
  :<|> authUsersInfo
  :<|> authUserInfo
  :<|> authUserPatch
  :<|> authUserPut
  :<|> authUserDelete
  :<|> authRestore
  :<|> authGroupGet 
  :<|> authGroupPost
  :<|> authGroupPut 
  :<|> authGroupPatch
  :<|> authGroupDelete
  :<|> authGroupList)

-- | Implementation of "signin" method
authSignin :: AuthMonad m
  => Maybe Login -- ^ Login query parameter
  -> Maybe Password -- ^ Password query parameter
  -> Maybe Seconds -- ^ Expire query parameter, how many seconds the token is valid
  -> m (OnlyField "token" SimpleToken) -- ^ If everything is OK, return token
authSignin mlogin mpass mexpire = runAuth $ do
  login <- require "login" mlogin 
  pass <- require "pass" mpass 
  Entity uid UserImpl{..} <- guardLogin login pass
  OnlyField <$> getAuthToken uid mexpire
  where 
  guardLogin login pass = do -- check login and password, return passed user
    muser <- runDB $ selectFirst [UserImplLogin ==. login] []
    let err = throw401 "Cannot find user with given combination of login and pass"
    case muser of 
      Nothing -> err
      Just user@(Entity _ UserImpl{..}) -> if passToByteString pass `verifyPassword` passToByteString userImplPassword 
        then return user
        else err

-- | Helper to get or generate new token for user
getAuthToken :: AuthMonad m
  => UserImplId -- ^ User for whom we want token
  -> Maybe Seconds -- ^ Expiration duration, 'Nothing' means default
  -> m SimpleToken -- ^ Old token (if it doesn't expire) or new one
getAuthToken uid mexpire = runAuth $ do 
  expire <- calcExpire mexpire
  mt <- getExistingToken  -- check whether there is already existing token
  case mt of 
    Nothing -> createToken expire -- create new token
    Just t -> touchToken t expire -- prolong token expiration time
  where
  getExistingToken = do -- return active token for specified user id
    t <- liftIO getCurrentTime 
    runDB $ selectFirst [AuthTokenUser ==. uid, AuthTokenExpire >. t] []

  createToken expire = do -- generate and save fresh token 
    token <- toText <$> liftIO nextRandom
    _ <- runDB $ insert AuthToken {
        authTokenValue = token 
      , authTokenUser = uid 
      , authTokenExpire = expire 
      }
    return token 

-- | Authorisation via code of single usage.
--
-- Implementation of 'AuthSigninGetCodeMethod' endpoint.
--
-- Logic of authorisation via this method is:
-- 
-- * Client sends GET request to 'AuthSigninGetCodeMethod' endpoint
--
-- * Server generates single use token and sends it via
--   SMS or email, defined in configuration by 'singleUseCodeSender' field.
--
-- * Client sends POST request to 'AuthSigninPostCodeMethod' endpoint
--
-- * Server responds with auth token.
--
-- * Client uses the token with other requests as authorisation
-- header
--
-- * Client can extend lifetime of token by periodically pinging
-- of 'AuthTouchMethod' endpoint
--
-- * Client can invalidate token instantly by 'AuthSignoutMethod'
--
-- * Client can get info about user with 'AuthTokenInfoMethod' endpoint.
--
-- See also: 'authSigninPostCode'
authSigninGetCode :: AuthMonad m 
  => Maybe Login -- ^ User login, required
  -> m Unit 
authSigninGetCode mlogin = runAuth $ do 
  login <- require "login" mlogin 
  uinfo <- runDB404 "user" $ readUserInfoByLogin login
  let uid = toKey $ respUserId uinfo 

  AuthConfig{..} <- getConfig
  code <- liftIO singleUseCodeGenerator 
  expire <- makeSingleUseExpire singleUseCodeExpire
  runDB $ registerSingleUseCode uid code expire
  liftIO $ singleUseCodeSender uinfo code 

  return Unit 

-- | Authorisation via code of single usage.
--
-- Logic of authorisation via this method is:
-- 
-- * Client sends GET request to 'AuthSigninGetCodeMethod' endpoint
--
-- * Server generates single use token and sends it via
--   SMS or email, defined in configuration by 'singleUseCodeSender' field.
--
-- * Client sends POST request to 'AuthSigninPostCodeMethod' endpoint
--
-- * Server responds with auth token.
--
-- * Client uses the token with other requests as authorisation
-- header
--
-- * Client can extend lifetime of token by periodically pinging
-- of 'AuthTouchMethod' endpoint
--
-- * Client can invalidate token instantly by 'AuthSignoutMethod'
--
-- * Client can get info about user with 'AuthTokenInfoMethod' endpoint.
--
-- See also: 'authSigninGetCode'
authSigninPostCode :: AuthMonad m 
  => Maybe Login -- ^ User login, required
  -> Maybe SingleUseCode -- ^ Received single usage code, required
  -> Maybe Seconds 
  -- ^ Time interval after which the token expires, 'Nothing' means 
  -- some default value
  -> m (OnlyField "token" SimpleToken)
authSigninPostCode mlogin mcode mexpire = runAuth $ do 
  login <- require "login" mlogin 
  code <- require "code" mcode

  uinfo <- runDB404 "user" $ readUserInfoByLogin login
  let uid = toKey $ respUserId uinfo 
  isValid <- runDB $ validateSingleUseCode uid code 
  unless isValid $ throw401 "Single usage code doesn't match"
  
  OnlyField <$> getAuthToken uid mexpire

-- | Calculate expiration timestamp for token
calcExpire :: Maybe Seconds -> AuthHandler UTCTime
calcExpire mexpire = do 
  t <- liftIO getCurrentTime
  AuthConfig{..} <- getConfig
  let requestedExpire = maybe defaultExpire fromIntegral mexpire 
  let boundedExpire = maybe requestedExpire (min requestedExpire) maximumExpire
  return $ boundedExpire `addUTCTime` t

-- prolong token with new timestamp
touchToken :: Entity AuthToken -> UTCTime -> AuthHandler SimpleToken
touchToken (Entity tid tok) expire = do
  runDB $ replace tid tok {
      authTokenExpire = expire 
    }
  return $ authTokenValue tok

-- | Implementation of "touch" method
authTouch :: AuthMonad m
  => Maybe Seconds -- ^ Expire query parameter, how many seconds the token should be valid by now. 'Nothing' means default value defined in server config.
  -> MToken '[] -- ^ Authorisation header with token 
  -> m Unit
authTouch mexpire token = runAuth $ do 
  Entity i mt <- guardAuthToken' (fmap unToken token) []
  expire <- calcExpire mexpire
  runDB $ replace i mt { authTokenExpire = expire }
  return Unit 

-- | Implementation of "token" method, return 
-- info about user binded to the token
authToken :: AuthMonad m
  => MToken '[] -- ^ Authorisation header with token 
  -> m RespUserInfo 
authToken token = runAuth $ do 
  i <- authUserByToken token
  runDB404 "user" . readUserInfo . fromKey $ i

-- | Getting user id by token
authUserByToken :: AuthMonad m => MToken '[] -> m UserImplId 
authUserByToken token = runAuth $ do 
  Entity _ mt <- guardAuthToken' (fmap unToken token) []
  return $ authTokenUser mt 

-- | Implementation of "signout" method
authSignout :: AuthMonad m
  => Maybe (Token '[]) -- ^ Authorisation header with token 
  -> m Unit
authSignout token = runAuth $ do 
  Entity i mt <- guardAuthToken' (fmap unToken token) []
  expire <- liftIO getCurrentTime
  runDB $ replace i mt { authTokenExpire = expire }
  return Unit 
  
-- | Checks given password and if it is invalid in terms of config
-- password validator, throws 400 error.
guardPassword :: Password -> AuthHandler ()
guardPassword p = do 
  AuthConfig{..} <- getConfig
  whenJust (passwordValidator p) $ throw400 . BS.fromStrict . encodeUtf8

-- | Implementation of "signup" method
authSignup :: AuthMonad m
  => ReqRegister -- ^ Registration info
  -> MToken' '["auth-register"] -- ^ Authorisation header with token 
  -> m (OnlyField "user" UserId)
authSignup ReqRegister{..} token = runAuth $ do 
  guardAuthToken token
  guardUserInfo
  guardPassword reqRegPassword
  strength <- getsConfig passwordsStrength
  i <- runDB $ do
    i <- createUser strength reqRegLogin reqRegPassword reqRegEmail reqRegPermissions
    whenJust reqRegGroups $ setUserGroups i
    return i
  return $ OnlyField . fromKey $ i 
  where 
    guardUserInfo = do 
      c <- runDB $ count [UserImplLogin ==. reqRegLogin]
      when (c > 0) $ throw400 "User with specified id is already registered"

-- | Implementation of get "users" method
authUsersInfo :: AuthMonad m
  => Maybe Page -- ^ Page num parameter
  -> Maybe PageSize -- ^ Page size parameter
  -> MToken' '["auth-info"] -- ^ Authorisation header with token
  -> m RespUsersInfo
authUsersInfo mp msize token = runAuth $ do 
  guardAuthToken token
  pagination mp msize $ \page size -> do 
    (users, total) <- runDB $ (,)
      <$> (do
        users <- selectList [] [Asc UserImplId, OffsetBy (fromIntegral $ page * size), LimitTo (fromIntegral size)]
        perms <- mapM (getUserPermissions . entityKey) users 
        groups <- mapM (getUserGroups . entityKey) users
        return $ zip3 users perms groups)
      <*> count ([] :: [Filter UserImpl])
    return RespUsersInfo {
        respUsersItems = (\(user, perms, groups) -> userToUserInfo user perms groups) <$> users 
      , respUsersPages = ceiling $ (fromIntegral total :: Double) / fromIntegral size
      }

-- | Implementation of get "user" method
authUserInfo :: AuthMonad m
  => UserId -- ^ User id 
  -> MToken' '["auth-info"] -- ^ Authorisation header with token
  -> m RespUserInfo
authUserInfo uid' token = runAuth $ do 
  guardAuthToken token
  runDB404 "user" $ readUserInfo uid'

-- | Implementation of patch "user" method
authUserPatch :: AuthMonad m
  => UserId -- ^ User id 
  -> PatchUser -- ^ JSON with fields for patching
  -> MToken' '["auth-update"] -- ^ Authorisation header with token
  -> m Unit
authUserPatch uid' body token = runAuth $ do 
  guardAuthToken token
  whenJust (patchUserPassword body) guardPassword 
  let uid = toSqlKey . fromIntegral $ uid'
  user <- guardUser uid 
  strength <- getsConfig passwordsStrength
  Entity _ user' <- runDB $ patchUser strength body $ Entity uid user 
  runDB $ replace uid user'
  return Unit

-- | Implementation of put "user" method
authUserPut :: AuthMonad m
  => UserId -- ^ User id 
  -> ReqRegister -- ^ New user
  -> MToken' '["auth-update"] -- ^ Authorisation header with token
  -> m Unit
authUserPut uid' ReqRegister{..} token = runAuth $ do 
  guardAuthToken token
  guardPassword reqRegPassword
  let uid = toSqlKey . fromIntegral $ uid'
  let user = UserImpl {
        userImplLogin = reqRegLogin
      , userImplPassword = ""
      , userImplEmail = reqRegEmail
      }
  user' <- setUserPassword reqRegPassword user 
  runDB $ do
    replace uid user'
    setUserPermissions uid reqRegPermissions
    whenJust reqRegGroups $ setUserGroups uid
  return Unit 

-- | Implementation of patch "user" method
authUserDelete :: AuthMonad m
  => UserId -- ^ User id 
  -> MToken' '["auth-delete"] -- ^ Authorisation header with token
  -> m Unit
authUserDelete uid' token = runAuth $ do 
  guardAuthToken token
  runDB $ deleteCascade (toKey uid' :: UserImplId)
  return Unit 

-- Generate new password for user. There is two phases, first, the method
-- is called without 'code' parameter. The system sends email with a restore code
-- to email. After that a call of the method with the code is needed to 
-- change password. Need configured SMTP server.
authRestore :: AuthMonad m
  => UserId -- ^ User id 
  -> Maybe RestoreCode
  -> Maybe Password
  -> m Unit
authRestore uid' mcode mpass = runAuth $ do 
  let uid = toKey uid'
  user <- guardUser uid 
  case mcode of 
    Nothing -> do 
      dt <- getsConfig restoreExpire
      t <- liftIO getCurrentTime
      AuthConfig{..} <- getConfig
      rc <- runDB $ getRestoreCode restoreCodeGenerator uid $ addUTCTime dt t 
      uinfo <- runDB404 "user" $ readUserInfo uid'
      sendRestoreCode uinfo rc 
    Just code -> do 
      pass <- require "password" mpass
      guardPassword pass
      guardRestoreCode uid code
      user' <- setUserPassword pass user
      runDB $ replace uid user'
  return Unit 

-- | Getting user by id, throw 404 response if not found
guardUser :: UserImplId -> AuthHandler UserImpl
guardUser uid = do 
  muser <- runDB $ get uid 
  case muser of 
    Nothing -> throw404 "User not found"
    Just user -> return user 

-- | If the token is missing or the user of the token
-- doesn't have needed permissions, throw 401 response
guardAuthToken :: forall perms m . (PermsList perms, AuthMonad m) => MToken perms -> m ()
guardAuthToken mt = runAuth $ void $ guardAuthToken' (fmap unToken mt) $ unliftPerms (Proxy :: Proxy perms)

-- | Same as `guardAuthToken` but returns record about the token
guardAuthToken' :: Maybe SimpleToken -> [Permission] -> AuthHandler (Entity AuthToken)
guardAuthToken' Nothing _ = throw401 "Token required"
guardAuthToken' (Just token) perms = do 
  t <- liftIO getCurrentTime
  mt <- runDB $ selectFirst [AuthTokenValue ==. token] []
  case mt of 
    Nothing -> throw401 "Token is not valid"
    Just et@(Entity _ AuthToken{..}) -> do 
      when (t > authTokenExpire) $ throwError $ err401 { errBody = "Token expired" }
      mu <- runDB $ get authTokenUser
      case mu of 
        Nothing -> throw500 "User of the token doesn't exist"
        Just UserImpl{..} -> do
          isAdmin <- runDB $ hasPerm authTokenUser adminPerm
          hasAllPerms <- runDB $ hasPerms authTokenUser perms 
          unless (isAdmin || hasAllPerms) $ throw401 $
            "User doesn't have all required permissions: " <> showb perms
          return et

-- | Rehash password for user
setUserPassword :: Password -> UserImpl -> AuthHandler UserImpl
setUserPassword pass user = do 
  strength <- getsConfig passwordsStrength 
  setUserPassword' strength pass user 

-- | Getting info about user group, requires 'authInfoPerm' for token
authGroupGet :: AuthMonad m
  => UserGroupId
  -> MToken' '["auth-info"] -- ^ Authorisation header with token
  -> m UserGroup
authGroupGet i token = runAuth $ do 
  guardAuthToken token
  runDB404 "user group" $ readUserGroup i 

-- | Inserting new user group, requires 'authUpdatePerm' for token
authGroupPost :: AuthMonad m
  => UserGroup
  -> MToken' '["auth-update"] -- ^ Authorisation header with token
  -> m (OnlyId UserGroupId)
authGroupPost ug token = runAuth $ do 
  guardAuthToken token
  runDB $ OnlyField <$> insertUserGroup ug

-- | Replace info about given user group, requires 'authUpdatePerm' for token
authGroupPut :: AuthMonad m
  => UserGroupId
  -> UserGroup
  -> MToken' '["auth-update"] -- ^ Authorisation header with token
  -> m Unit
authGroupPut i ug token = runAuth $ do 
  guardAuthToken token
  runDB $ updateUserGroup i ug 
  return Unit

-- | Patch info about given user group, requires 'authUpdatePerm' for token
authGroupPatch :: AuthMonad m
  => UserGroupId
  -> PatchUserGroup
  -> MToken' '["auth-update"] -- ^ Authorisation header with token
  -> m Unit
authGroupPatch i up token = runAuth $ do 
  guardAuthToken token
  runDB $ patchUserGroup i up 
  return Unit 

-- | Delete all info about given user group, requires 'authDeletePerm' for token
authGroupDelete :: AuthMonad m
  => UserGroupId
  -> MToken' '["auth-delete"] -- ^ Authorisation header with token
  -> m Unit
authGroupDelete i token = runAuth $ do 
  guardAuthToken token
  runDB $ deleteUserGroup i 
  return Unit 

-- | Get list of user groups, requires 'authInfoPerm' for token 
authGroupList :: AuthMonad m
  => Maybe Page
  -> Maybe PageSize
  -> MToken' '["auth-info"] -- ^ Authorisation header with token
  -> m (PagedList UserGroupId UserGroup)
authGroupList mp msize token = runAuth $ do 
  guardAuthToken token
  pagination mp msize $ \page size -> do 
    (groups, total) <- runDB $ (,)
      <$> (do
        is <- selectKeysList [] [Asc AuthUserGroupId, OffsetBy (fromIntegral $ page * size), LimitTo (fromIntegral size)]
        forM is $ (\i -> fmap (WithField i) <$> readUserGroup i) . fromKey)
      <*> count ([] :: [Filter AuthUserGroup])
    return PagedList {
        pagedListItems = catMaybes groups
      , pagedListPages = ceiling $ (fromIntegral total :: Double) / fromIntegral size
      }