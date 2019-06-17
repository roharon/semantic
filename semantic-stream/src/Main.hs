{-# LANGUAGE AllowAmbiguousTypes, DeriveAnyClass, LambdaCase, QuantifiedConstraints, ScopedTypeVariables, Rank2Types,
             TypeApplications, TypeFamilies #-}

module Main where

import Prelude hiding (head)
import Prologue

import           Control.Effect
import           Control.Effect.Catch
import           Control.Effect.Error
import           Control.Effect.Lift
import           Control.Effect.Reader
import qualified Control.Exception
import qualified Control.Foldl as Foldl
import           Control.Lens.Getter
import           Control.Monad.Catch (MonadMask)
import           Control.Monad.IO.Unlift
import qualified Control.Monad.Reader as MTL
import qualified Data.ByteString.Streaming.Aeson as Aeson
import qualified Data.ByteString.Streaming.Char8 as ByteStream
import           Data.Generics.Product
import           Data.Tagged
import           Data.Text.Encoding
import           Data.Vector (Vector)
import qualified Git
import qualified Git.Libgit2
import qualified Options.Applicative as Opt
import           Streaming
import qualified Streaming.Conduit as Conduit
import qualified Streaming.Prelude as Streaming
import qualified Data.Conduit  as Conduit
import qualified Data.Conduit.List  as Conduit

import Data.AST
import qualified Data.Tag as Data (Tag)
import qualified Semantic.Api.V1.CodeAnalysisPB as Api
import qualified Language.Go.Assignment as Go

type ByteStream = ByteStream.ByteString

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

getBlobOid :: Git.TreeEntry r -> Maybe (Git.BlobOid r)
getBlobOid = \case
  Git.BlobEntry i _ -> Just i
  _                 -> Nothing

streamBlobContents :: Monad m => Git.Blob r m -> ByteStream m ()
streamBlobContents blob = case Git.blobContents blob of
  Git.BlobString b      -> ByteStream.fromStrict b
  Git.BlobStringLazy b  -> ByteStream.fromLazy b
  Git.BlobStream s      -> conduitToByteStream s

parseFromByteStream :: ByteStream (ByteStream m) () -> ByteStream m Go.Term
parseFromByteStream = undefined

tagWithSlicing :: ByteStream m Go.Term -> Stream (Of Data.Tag) m ()
tagWithSlicing = undefined

tagBlob :: forall sig m r .
           ( Member (Lift GitM) sig
           , Carrier sig m
           , MonadIO m
           )
        => Git.Blob r GitM -> m Api.File
tagBlob blob =
  hoist @_ @_ @m sendM (streamBlobContents blob)        -- ByteStream m ()
  & ByteStream.copy                                     -- ByteStream (ByteStream m) ()
  & parseFromByteStream                                 -- ByteStream m Go.Term
  & tagWithSlicing                                      -- Stream (Of Data.Tag) m ()
  & converting                                          -- Stream (Of Api.Symbol)
  & Foldl.purely Streaming.fold_ (Foldl.vector @Vector) -- m (Vector Api.Symbol)
  & fmap (makeFile blob)                                -- m Api.File

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
    & Streaming.mapMaybe (getBlobOid . snd)               -- Stream (Of (Git.BlobOid r)) m ()
    & Streaming.mapM (sendM . Git.lookupBlob @_ @n)       -- Stream (Of (Git.Blob m r)) m ()
    & Streaming.mapM tagBlob                              -- Stream (Of Api.File) m ()
    & Foldl.purely Streaming.fold_ (Foldl.vector @Vector) -- m (Vector Api.File)
    & fmap Aeson.encode                                   -- m (ByteStream m ())
    >>= ByteStream.stdout                                 -- m ()


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


-- TODO: we can unsafeCoerce this away
conduitToByteStream :: Monad m => Conduit.ConduitT () ByteString m () -> ByteStream m ()
conduitToByteStream cnd = Conduit.runConduit (Conduit.transPipe MTL.lift cnd Conduit..| Conduit.mapM_ ByteStream.chunk)
