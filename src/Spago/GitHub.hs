{-# LANGUAGE ViewPatterns #-}
module Spago.GitHub where

import           Spago.Prelude

import qualified Control.Retry      as Retry
import qualified Data.Text          as Text
import qualified Data.Text.Encoding
import qualified GitHub
import qualified System.Environment

import qualified Spago.GlobalCache  as GlobalCache
import qualified Spago.Messages     as Messages


tagCacheFile, tokenCacheFile :: IsString t => t
tagCacheFile = "package-sets-tag.txt"
tokenCacheFile = "github-token.txt"


login :: Spago m => m ()
login = do
 maybeToken <- liftIO (System.Environment.lookupEnv githubTokenEnvVar)
 globalCacheDir <- GlobalCache.getGlobalCacheDir

 case maybeToken of
   Nothing -> die Messages.getNewGitHubToken
   Just (Text.pack -> token) -> do
     echo "Token read, authenticating with GitHub.."
     username <- getUsername token
     echo $ "Successfully authenticated as " <> surroundQuote username
     writeTextFile (Text.pack $ globalCacheDir </> tokenCacheFile) token
  where
    getUsername token = do
      result <- liftIO $ GitHub.executeRequest
        (GitHub.OAuth $ Data.Text.Encoding.encodeUtf8 token)
        GitHub.userInfoCurrentR
      case result of
        Left err              -> die $ Messages.failedToReachGitHub err
        Right GitHub.User{..} -> pure $ GitHub.untagName userLogin


readToken :: Spago m => m GitHub.Auth
readToken = do
  token <- readFromEnv <|> readFromFile <|> err
  pure $ GitHub.OAuth $ encodeUtf8 token
  where
    err = die "Pursuit authentication token not found. Try running `spago login` first."

    readFromEnv = liftIO (System.Environment.lookupEnv githubTokenEnvVar) >>= \case
      Nothing -> empty
      Just (Text.pack -> token) -> return token

    readFromFile = do
      globalCacheDir <- GlobalCache.getGlobalCacheDir
      assertDirectory globalCacheDir
      readTextFile $ pathFromText $ Text.pack $ globalCacheDir </> tokenCacheFile


getLatestPackageSetsTag :: Spago m => m (Either SomeException Text)
getLatestPackageSetsTag = do
  globalCacheDir <- GlobalCache.getGlobalCacheDir
  assertDirectory globalCacheDir
  let globalPathToCachedTag = globalCacheDir </> tagCacheFile
  let writeTagCache releaseTagName = writeTextFile (Text.pack globalPathToCachedTag) releaseTagName
  let readTagCache = try $ readTextFile $ pathFromText $ Text.pack globalPathToCachedTag
  let downloadTagToCache =
        try (Retry.recoverAll (Retry.fullJitterBackoff 50000 <> Retry.limitRetries 5) $ \_ -> getLatestRelease) >>= \case
          Left (err :: SomeException) -> echoDebug $ Messages.failedToReachGitHub err
          Right releaseTagName -> writeTagCache releaseTagName

  whenM (shouldRefreshFile globalPathToCachedTag) downloadTagToCache

  readTagCache

  where
    getLatestRelease :: Spago m => m Text
    getLatestRelease = do
      maybeToken :: Either SomeException GitHub.Auth <- try readToken
      f <- case hush maybeToken of
        Nothing -> pure GitHub.executeRequest'
        Just token -> do
          echoDebug "Using cached GitHub token for getting the latest release.."
          pure $ GitHub.executeRequest token
      result <- liftIO $ f $ GitHub.latestReleaseR "purescript" "package-sets"

      case result of
        Left err                 -> die $ Messages.failedToReachGitHub err
        Right GitHub.Release{..} -> pure releaseTagName
