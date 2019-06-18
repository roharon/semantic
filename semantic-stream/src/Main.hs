{-# LANGUAGE AllowAmbiguousTypes, DeriveAnyClass, LambdaCase, QuantifiedConstraints, Rank2Types, ScopedTypeVariables,
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
import           Data.Aeson (ToJSON (..))
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Lens as Lens
import qualified Data.ByteString.Streaming.Aeson as Aeson
import qualified Data.ByteString.Streaming.Char8 as ByteStream
import qualified Data.Conduit as Conduit
import qualified Data.Conduit.List as Conduit
import           Data.Generics.Product
import           Data.Tagged
import qualified Data.Text.Lazy as LT
import           Data.Text.Lazy.Encoding as LT
import           Data.Vector (Vector)
import           GHC.Conc
import qualified Git
import qualified Git.Libgit2
import qualified Options.Applicative as Opt
import           Streaming
import qualified Streaming.Conduit as Conduit
import qualified Streaming.Prelude as Streaming

import           Data.AST
import           Data.Language
import qualified Data.Tag as Data (Tag)
import qualified Language.Go.Assignment as Go
import qualified Semantic.Api.V1.CodeAnalysisPB as Api

type ByteStream = ByteStream.ByteString

data Config = Config
  { _outputFormat :: OutputFormat
  , _bufferSize   :: Int
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
options = Config
  <$> outputFormat
  <*> Opt.option Opt.auto (Opt.long "buffer-size" <> Opt.value numCapabilities)
  <*> Opt.strArgument (Opt.help "[DIRECTORY]")

data FatalException
  = CouldNotResolveHEAD
  | UnhandledException SomeException
    deriving (Show, Control.Exception.Exception)

type GitM = MTL.ReaderT Git.Libgit2.LgRepo IO

getBlobOid :: Git.TreeEntry r -> Maybe (Git.BlobOid r)
getBlobOid = \case
  Git.BlobEntry i _ -> Just i
  _                 -> Nothing

streamBlobContents :: Git.MonadGit Git.Libgit2.LgRepo m => Git.Blob Git.Libgit2.LgRepo m -> ByteStream m ()
streamBlobContents = ByteStream.mwrap . fmap ByteStream.fromLazy . Git.blobToLazyByteString

data Result = Result
  { _totalLength :: Int
  , _lastLine    :: LT.Text
  } deriving (Eq, Show, Ord, Generic, ToJSON)

toResult :: Of (Maybe LB.ByteString) (Of Int ()) -> Result
toResult (str :> (int :> ())) = Result int (LT.decodeUtf8 (fromMaybe "ERROR" str))

summarizeBlob :: Git.MonadGit Git.Libgit2.LgRepo m => Git.Blob Git.Libgit2.LgRepo m -> m Result
summarizeBlob blob
  = streamBlobContents blob            -- ByteStream m ()
  & ByteStream.copy                    -- ByteStream (ByteStream m) ()
  & ByteStream.length                  -- ByteStream m (Of Int ())
  & ByteStream.lines                   -- Stream (ByteString m) m (Of Int ())
  & Streaming.mapped ByteStream.toLazy -- Stream (Of LB.ByteString) m (Of Int ())
  & Streaming.last                     -- m (Of (Maybe LB.ByteString) (Of Int ()))
  & fmap toResult                      -- m Result

isAppropriate :: Git.TreeFilePath -> Git.TreeEntry r -> Bool
isAppropriate (Lens.Chars p) ent
  | Git.BlobEntry _ Git.PlainBlob <- ent, languageForFilePath p /= Unknown = True
  | otherwise = False


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
    & Streaming.filter (uncurry isAppropriate)            -- Stream (Of (TreeFilePath, TreeEntry r)) m ()
    & Streaming.mapMaybe (getBlobOid . snd)               -- Stream (Of (Git.BlobOid r)) m ()
    & Streaming.mapM (sendM . Git.lookupBlob @_ @n)       -- Stream (Of (Git.Blob m r)) m ()
    & Streaming.mapM (sendM . summarizeBlob)              -- Stream (Of Result) m ()
    & Foldl.purely Streaming.fold_ (Foldl.vector @Vector) -- m (Vector Result)
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
  -- let buffer = Streaming.Concurrent.bounded
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
