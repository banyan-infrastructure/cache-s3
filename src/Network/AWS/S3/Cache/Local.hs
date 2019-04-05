{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module      : Network.AWS.S3.Cache.Local
-- Copyright   : (c) FP Complete 2017
-- License     : BSD3
-- Maintainer  : Alexey Kuleshevich <alexey@fpcomplete.com>
-- Stability   : experimental
-- Portability : non-portable
--

module Network.AWS.S3.Cache.Local where

import Control.Exception.Safe (MonadCatch, MonadThrow, throwString)
import Control.Monad (void, when)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Logger
import Control.Monad.Trans.Resource (MonadResource)
import Crypto.Hash (Digest, HashAlgorithm)
import Crypto.Hash.Conduit
import Data.ByteString as S
import Data.Conduit
import Data.Conduit.Binary
import Data.Conduit.List as C
import Data.Conduit.Tar
import Data.List as L
import Data.Maybe as Maybe
import Data.Monoid ((<>))
import Data.Text as T
import Data.Void
import Data.Word
import Network.AWS.S3.Cache.Types
import Prelude as P
import System.Directory
import System.FilePath
import System.IO hiding (openTempFile)
import System.IO.Temp

tarFiles :: (MonadCatch m, MonadResource m, MonadLogger m) =>
            [FilePath] -> [FilePath] -> ConduitM a ByteString m ()
tarFiles dirs relativeDirs = do
  logDebugN "Preparing files for saving in the cache."
  dirsCanonical <- liftIO $ P.mapM canonicalizePath dirs
  uniqueDirs <- Maybe.catMaybes <$> P.mapM skipMissing (removeSubpaths dirsCanonical ++ relativeDirs)
  if P.null uniqueDirs
    then logErrorN "No paths to cache has been specified."
    else sourceList uniqueDirs .| filePathConduit .| void tar
  where
    skipMissing fp = do
      exist <- liftIO $ doesPathExist fp
      if exist
        then do
          logInfoN $ "Caching: " <> T.pack fp
          return $ Just fp
        else do
          logWarnN $ "File path is skipped since it is missing: " <> T.pack fp
          return Nothing


-- | Will remove any subfolders or files. Imput is expected to be a list of canonicalized file
-- paths.
removeSubpaths :: [FilePath] -> [FilePath]
removeSubpaths dirsCanonical =
  L.map joinPath $ removePrefixSorted $ L.sort $ L.map splitDirectories dirsCanonical
  where
    removePrefixSorted :: [[FilePath]] -> [[FilePath]]
    removePrefixSorted []     = []
    removePrefixSorted (x:xs) = x : L.filter (not . (x `isPathPrefixOf`)) xs
    isPathPrefixOf :: [FilePath] -> [FilePath] -> Bool
    isPathPrefixOf [] _          = True
    isPathPrefixOf _ []          = False
    isPathPrefixOf (x:xs) (y:ys) = equalFilePath x y && isPathPrefixOf xs ys

prepareCache ::
     (HashAlgorithm h, MonadResource m)
  => Compression -> ConduitM ByteString Void m (TempFile, Word64, Digest h, Compression)
prepareCache compression = do
  (releaseKey, fileName, tmpHandle) <-
    openTempFile Nothing ("cache-s3.tar" <.> T.unpack (getCompressionName compression))
  hash <-
    getZipSink
      (ZipSink (getCompressionConduit compression .| sinkHandle tmpHandle) *>
       ZipSink sinkHash)
  cSize <-
    liftIO $ do
      hFlush tmpHandle
      cSize <- hTell tmpHandle
      hSeek tmpHandle AbsoluteSeek 0
      return cSize
  let tmpFile = TempFile fileName releaseKey tmpHandle
  return (tmpFile, fromInteger cSize, hash, compression)


-- | Create a compressed tarball in the temporary directory. Compute the hash value of the tarball
-- prior to the compression, in order to avoid any possible nondeterminism with future compression
-- algorithms. Returns the computed hash and the file handle where tarball can be read from.
getCacheHandle ::
     (HashAlgorithm h, MonadCatch m, MonadResource m, MonadLogger m)
  => [FilePath]
  -> [FilePath]
  -> h
  -> Compression
  -> m (TempFile, Word64, Digest h, Compression)
getCacheHandle dirs relativeDirs _ comp = runConduit $ tarFiles dirs relativeDirs .| prepareCache comp


-- | Restores all of the files from the tarball and computes the hash at the same time.
restoreFilesFromCache ::
     (MonadIO m, MonadThrow m, MonadResource m, HashAlgorithm h)
  => FileOverwrite
  -> (LogLevel -> Text -> IO ())
  -> Compression -- ^ Compression algorithm the stream is expected to be compressed with.
  -> h -- ^ Hashing algorithm to use for computation of hash value of the extracted tarball.
  -> ConduitM ByteString Void m (Digest h)
restoreFilesFromCache (FileOverwrite level) logger comp _ =
  getDeCompressionConduit comp .|
  getZipConduit (ZipConduit (untarWithFinalizers restoreFile') *> ZipConduit sinkHash)
  where
    restoreFile' fi = do
      case fileType fi of
        FTDirectory -- Make sure nested folders are created:
         -> liftIO $ createDirectoryIfMissing True (decodeFilePath (filePath fi))
        FTNormal -> do
          let fp = getFileInfoPath fi
          fileExist <- liftIO $ doesFileExist fp
          when fileExist $ do
            when (level == LevelError) $
              throwString $ "File with name already exists: " ++ fp
            liftIO $ logger level $ "Restoring an existing file: " <> T.pack fp
        _ -> return ()
      restoreFile fi
