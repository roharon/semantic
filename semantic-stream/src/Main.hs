{-# LANGUAGE AllowAmbiguousTypes, DeriveAnyClass, LambdaCase, QuantifiedConstraints, Rank2Types, ScopedTypeVariables,
             TypeApplications, TypeFamilies, ViewPatterns #-}

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
import           Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Streaming.Aeson as Aeson
import qualified Data.ByteString.Streaming.Char8 as ByteStream
import qualified Data.Conduit as Conduit
import qualified Data.Conduit.List as Conduit
import           Data.Generics.Product
import           Data.Tagged
import qualified Data.Text as T
import           Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
import           Data.Text.Lazy.Encoding as TL
import           Data.Vector (Vector)
import           GHC.Conc
import qualified Git
import qualified Git.Libgit2
import qualified Options.Applicative as Opt
import           Streaming
import qualified Streaming.Conduit as Conduit
import qualified Streaming.Prelude as Streaming

-- import           Data.AST
import Data.Language
-- import qualified Data.Tag as Data (Tag)
-- import qualified Language.Go.Assignment as Go
-- import qualified Semantic.Api.V1.CodeAnalysisPB as Api

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


data Result = Result
  { _totalLength :: Int
  , _lastLine    :: T.Text
  } deriving (Eq, Show, Ord, Generic, ToJSON)

toResult :: Of (Maybe B.ByteString) (Of Int ()) -> Result
toResult (str :> (int :> ())) = Result int (T.decodeUtf8 (fromMaybe "error" str))

summarize :: ( MonadMask m
             , MonadUnliftIO m
             , Git.MonadGit r m
             , Git.Libgit2.HasLgRepo m
             )
          => Git.Blob r m
          -> m Result
summarize
  = fmap toResult                        -- m Result
  . Streaming.last                       -- m (Of (Maybe Strict.ByteString) (Of Int ()))
  . Streaming.mapped ByteStream.toStrict -- Stream (Of Strict.ByteString) m (Of Int ())
  . ByteStream.lines                     -- Stream (ByteString m) m Int
  . ByteStream.length                    -- ByteStream m Int
  . ByteStream.copy                      -- ByteStream (ByteStream m) ()
  . ByteStream.mwrap                     -- ByteStream m ()
  . fmap ByteStream.fromLazy             -- m (ByteStream m ())
  . Git.blobToLazyByteString             -- m LB.ByteString


isAppropriate :: Git.TreeFilePath -> Git.TreeEntry r -> Bool
isAppropriate (B.unpack -> p) ent
  | Git.BlobEntry _ Git.PlainBlob <- ent = languageForFilePath p == Go
  | otherwise = False



pipeline :: forall n m sig r .
            ( Git.Libgit2.HasLgRepo n
            , Git.MonadGit r n
            , MonadUnliftIO n
            , MonadMask n
            , Member (Lift n) sig
            , Member (Error FatalException) sig
            , Carrier sig m
            , MonadIO n
            , MonadIO m
            ) => m ()
pipeline = do
  let git :: n a -> m a
      git = sendM @n

  headRef  <- git (Git.resolveReference "HEAD") >>= maybeM (throwError CouldNotResolveHEAD)
  headTree <- git (Git.lookupCommit (Tagged headRef) >>= Git.lookupTree . Git.commitTree)

  -- This 'hoist' is necessary so that we can run gitStream in 'm' rather than 'n'
  let gitStream = hoist @_ @n @m sendM (Conduit.toStream (Git.sourceTreeEntries headTree))

  ByteStream.stdout =<<
    ( fmap Aeson.encode                                     -- m (ByteStream m ())
    . Foldl.purely Streaming.fold_ (Foldl.vector @Vector)   -- m (Vector Result)
    . Streaming.mapM (git . (Git.lookupBlob >=> summarize)) -- Stream (Of Result) m ()
    . Streaming.mapMaybe (getBlobOid . snd)                 -- Stream (Of (Git.BlobOid r)) m ()
    . Streaming.filter (uncurry isAppropriate)              -- Stream (Of (TreeFilePath, TreeEntry r)) m ()
    $ gitStream                                             -- Stream (Of (TreeFilePath, TreeEntry r)) m ()
    )




main :: IO ()
main = do
  config <- Opt.execParser (Opt.info options Opt.fullDesc)
  let repoOptions = Git.RepositoryOptions { Git.repoPath = config^.typed @FilePath
                                          , Git.repoWorkingDir = Nothing
                                          , Git.repoIsBare = False
                                          , Git.repoAutoCreate = False
                                          }

  result <- Git.withRepository' (Git.Libgit2.lgFactory @IO) repoOptions
    $ runM
    . withCatch
    . runError @FatalException
    . flip catchSync (throwError . UnhandledException)
    . runReader config
    $ pipeline @(MTL.ReaderT Git.Libgit2.LgRepo IO)

  result & either Control.Exception.throw pure


-- TODO: we can unsafeCoerce this away
conduitToByteStream :: Monad m => Conduit.ConduitT () ByteString m () -> ByteStream m ()
conduitToByteStream cnd = Conduit.runConduit (Conduit.transPipe MTL.lift cnd Conduit..| Conduit.mapM_ ByteStream.chunk)
