{-# LANGUAGE DeriveAnyClass, LambdaCase, ScopedTypeVariables, TypeApplications, TypeFamilies, QuantifiedConstraints, AllowAmbiguousTypes #-}
{-# OPTIONS_GHC -fprint-explicit-kinds #-}

module Main where

import Prelude hiding (head)
import Prologue

import Control.Effect
import Control.Effect.Catch
import Control.Effect.Error
import Control.Effect.Lift
import Control.Effect.Reader
import Control.Lens.Getter
import Control.Monad.IO.Unlift
import qualified Control.Monad.Reader as MTL
import Data.Generics.Product
import qualified Control.Exception
import Control.Monad.Catch (MonadMask)
import Data.Tagged
import qualified Git
import qualified Git.Libgit2
import qualified Options.Applicative as Opt
import qualified Streaming.Conduit as Conduit
import qualified Streaming.Prelude as Streaming
import Data.Text.Encoding
import Data.Vector (Vector)
import Streaming
import qualified Control.Foldl as Foldl
import qualified Data.ByteString.Streaming.Char8 as ByteStream
import qualified Data.ByteString.Streaming.Aeson as Aeson

data Config = Config
  { _outputFormat :: OutputFormat
  , _gitDirectory :: FilePath
  } deriving (Eq, Show, Generic)

data OutputFormat
  = AsProto
  | AsJSON
    deriving (Eq, Show)

outputFormat :: Opt.Parser OutputFormat
outputFormat = proto <|> json where
  json = Opt.flag AsJSON AsJSON (Opt.long "json")
  proto = Opt.flag' AsProto (Opt.long "proto")

options :: Opt.Parser Config
options = Config <$> outputFormat <*> Opt.strArgument (Opt.help "[DIRECTORY]")

data FatalException
  = CouldNotResolveHEAD
  | UnhandledException SomeException
    deriving (Show, Control.Exception.Exception)

type GitM = MTL.ReaderT Git.Libgit2.LgRepo IO

isInterestingTreeEntry :: Git.TreeEntry r -> Bool
isInterestingTreeEntry = \case
  Git.BlobEntry _ _ -> True
  _                 -> False

pipeline :: forall m sig n r .
            ( n ~ GitM
            , Member (Lift n) sig
            , Member (Error FatalException) sig
            , Carrier sig m
            , MonadIO m
            ) => m ()
pipeline = do

  mHeadRef <- sendM (Git.resolveReference @_ @n "HEAD")
  headRef <- maybeM (throwError CouldNotResolveHEAD) mHeadRef
  headCommit <- sendM . Git.lookupCommit @_ @n . Tagged $ headRef
  headTree <- sendM . Git.lookupTree @_ @n . Git.commitTree $ headCommit
  let cond = Conduit.toStream $ Git.sourceTreeEntries @_ @n headTree
  let files = hoist @_ @n @m sendM cond

  files
    & Streaming.filter (isInterestingTreeEntry . snd)
    & Streaming.map (decodeUtf8 . fst)
    & Foldl.purely Streaming.fold_ (Foldl.vector @Vector)
    & fmap Aeson.encode
    >>= ByteStream.stdout


main :: IO ()
main = do
  config <- Opt.execParser (Opt.info options Opt.fullDesc)
  let repoOptions = Git.RepositoryOptions { Git.repoPath = config^.typed @FilePath
                                          , Git.repoWorkingDir = Nothing
                                          , Git.repoIsBare = False
                                          , Git.repoAutoCreate = False
                                          }

  result <- Git.withRepository' Git.Libgit2.lgFactory repoOptions
    $ runM @GitM
    . withCatch
    . runError @FatalException
    . flip catchSync (throwError . UnhandledException)
    . runReader config
    $ pipeline

  result & either Control.Exception.throw pure


