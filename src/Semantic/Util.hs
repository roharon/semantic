-- {-# LANGUAGE GeneralizedNewtypeDeriving, ScopedTypeVariables, TypeFamilies, TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables, TypeFamilies, TypeOperators #-}
{-# OPTIONS_GHC -Wno-missing-signatures -Wno-missing-export-lists #-}
module Semantic.Util where

import Prelude hiding (id, (.), readFile)

import           Analysis.Abstract.Caching
import           Analysis.Abstract.Collecting
import           Control.Abstract
import           Control.Abstract.Matching
import           Control.Arrow
import           Control.Category
import           Control.Exception (displayException)
import           Control.Monad.Effect.Trace (runPrintingTrace)
import           Control.Rule
import           Control.Rule.Engine.Builtin
import           Data.Abstract.Address.Monovariant as Monovariant
import           Data.Abstract.Address.Precise as Precise
import           Data.Abstract.BaseError (BaseError (..))
import           Data.Abstract.Evaluatable
import           Data.Abstract.Module
import qualified Data.Abstract.ModuleTable as ModuleTable
import           Data.Abstract.Package
import           Data.Abstract.Value.Concrete as Concrete
import           Data.Abstract.Value.Type as Type
import           Data.Blob
import           Data.Coerce
import           Data.Graph (topologicalSort)
import           Data.History
import qualified Data.Language as Language
import           Data.List (uncons)
import           Data.Machine
import           Data.Project hiding (readFile)
import           Data.Quieterm (quieterm)
import           Data.Record
import           Data.Sum (weaken)
import qualified Data.Sum as Sum
import qualified Data.Syntax.Literal as Literal
import           Data.Term
import           Language.Haskell.HsColour
import           Language.Haskell.HsColour.Colourise
import           Parsing.Parser
import           Prologue hiding (weaken)
import           Refactoring.Core
import           Reprinting.Tokenize
import           Reprinting.Translate
import           Reprinting.Typeset
import           Semantic.Config
import           Semantic.Graph
import           Semantic.IO as IO
import           Semantic.Task
import           Semantic.Telemetry (LogQueue, StatQueue)
import           System.Exit (die)
import           System.FilePath.Posix (takeDirectory)
import           Text.Show.Pretty (ppShow)

justEvaluating
  = runM
  . runState lowerBound
  . runFresh 0
  . runPrintingTrace
  . fmap reassociate
  . runLoadError
  . runUnspecialized
  . runEnvironmentError
  . runEvalError
  . runResolutionError
  . runAddressError
  . runValueError

newtype UtilEff a = UtilEff
  { runUtilEff :: Eff '[ Function Precise (Value Precise UtilEff)
                       , Exc (LoopControl Precise)
                       , Exc (Return Precise)
                       , Env Precise
                       , Deref (Value Precise UtilEff)
                       , Allocator Precise
                       , Reader ModuleInfo
                       , Modules Precise
                       , Reader (ModuleTable (NonEmpty (Module (ModuleResult Precise))))
                       , Reader Span
                       , Reader PackageInfo
                       , Resumable (BaseError (ValueError Precise UtilEff))
                       , Resumable (BaseError (AddressError Precise (Value Precise UtilEff)))
                       , Resumable (BaseError ResolutionError)
                       , Resumable (BaseError EvalError)
                       , Resumable (BaseError (EnvironmentError Precise))
                       , Resumable (BaseError (UnspecializedError (Value Precise UtilEff)))
                       , Resumable (BaseError (LoadError Precise))
                       , Trace
                       , Fresh
                       , State (Heap Precise (Value Precise UtilEff))
                       , Lift IO
                       ] a
  }

checking
  = runM @_ @IO
  . runState (lowerBound @(Heap Monovariant Type))
  . runFresh 0
  . runPrintingTrace
  . runTermEvaluator @_ @Monovariant @Type
  . caching
  . providingLiveSet
  . fmap reassociate
  . runLoadError
  . runUnspecialized
  . runResolutionError
  . runEnvironmentError
  . runEvalError
  . runAddressError
  . runTypes

evalGoProject         = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.Go)         goParser
evalRubyProject       = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.Ruby)       rubyParser
evalPHPProject        = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.PHP)        phpParser
evalPythonProject     = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.Python)     pythonParser
evalJavaScriptProject = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.JavaScript) typescriptParser
evalTypeScriptProject = justEvaluating <=< evaluateProject (Proxy :: Proxy 'Language.TypeScript) typescriptParser

typecheckGoFile = checking <=< evaluateProjectWithCaching (Proxy :: Proxy 'Language.Go) goParser
typecheckRubyFile = checking <=< evaluateProjectWithCaching (Proxy :: Proxy 'Language.Ruby) rubyParser

callGraphProject parser proxy opts paths = runTaskWithOptions opts $ do
  blobs <- catMaybes <$> traverse readFile (flip File (Language.reflect proxy) <$> paths)
  package <- parsePackage parser (Project (takeDirectory (maybe "/" fst (uncons paths))) blobs (Language.reflect proxy) [])
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  x <- runCallGraph proxy False modules package
  pure (x, (() <$) <$> modules)

callGraphRubyProject = callGraphProject rubyParser (Proxy @'Language.Ruby) debugOptions


renameKey :: (Literal.TextElement :< fs, Literal.KeyValue :< fs, Apply Functor fs) => Term (Sum fs) (Record (History ': fields)) -> Term (Sum fs) (Record (History ': fields))
renameKey p = case Sum.project (termOut p) of
  Just (Literal.KeyValue k v)
    | Just (Literal.TextElement x) <- Sum.project (termOut k)
    , x == "\"foo\""
    -> let newKey = termIn (termAnnotation k) (inject (Literal.TextElement "\"fooA\""))
       in remark Refactored (termIn (termAnnotation p) (inject (Literal.KeyValue newKey v)))
  _ -> Term (fmap renameKey (unTerm p))

arrayMatcher :: forall fs ann term . (Literal.Array :< fs, term ~ Term (Sum fs) ann)
            => Matcher term (Literal.Array term)
arrayMatcher = matchM hash target
  where hash :: term -> Maybe (Literal.Array term)
        hash = projectTerm

increaseNumbers :: (Literal.Float :< fs, Apply Functor fs) => Term (Sum fs) (Record (History ': fields)) -> Term (Sum fs) (Record (History ': fields))
increaseNumbers p = case Sum.project (termOut p) of
  Just (Literal.Float t) -> remark Refactored (termIn (termAnnotation p) (inject (Literal.Float (t <> "0"))))
  Nothing                -> Term (fmap increaseNumbers (unTerm p))

hashMatcher :: forall fs ann term . (Literal.Hash :< fs, term ~ Term (Sum fs) ann)
            => Matcher term (Literal.Hash term)
hashMatcher = matchM hash target
  where hash :: term -> Maybe (Literal.Hash term)
        hash = projectTerm

testHashMatcher = do
  (src, tree) <- testJSONFile
  runMatcher hashMatcher tree

findHashes :: ( Apply Functor syntax
              , Apply Foldable syntax
              , Literal.Hash :< syntax
              , term ~ Term (Sum syntax) ann
              )
           => Rule eff term (Either term (term, Literal.Hash term))
findHashes = fromMatcher "findHashes" hashMatcher

addKVPair :: forall effs syntax ann fields term
             . ( Apply Functor syntax
               , Apply Foldable syntax
               , Literal.Float :< syntax
               , Literal.Hash :< syntax
               , Literal.Array :< syntax
               , Literal.TextElement :< syntax
               , Literal.KeyValue :< syntax
               , ann ~ Record (History ': fields)
               , term ~ Term (Sum syntax) ann
               )
           => Rule effs (Either term (term, Literal.Hash term)) term
addKVPair = fromPlan "addKVPair" $ do
  t <- await
  Data.Machine.yield (either id injKVPair t)
  where
    injKVPair :: (term, Literal.Hash term) -> term
    injKVPair (origTerm, Literal.Hash xs) =
      remark Refactored (injectTerm ann (Literal.Hash (xs <> [newItem])))
      where
        newItem = termIn ann (inject (Literal.KeyValue k v))
        k = termIn ann (inject (Literal.TextElement "\"added\""))
        v = termIn ann (inject (Literal.Array []))
        ann = termAnnotation origTerm

testAddKVPair = do
  (src, tree) <- testJSONFile
  tagged <- runM $ {- ensureAccurateHistory <$> -} cata (toAlgebra (addKVPair . findHashes)) (markUnmodified tree)
  let toks = tokenizing src tagged
  pure (toks, tagged)
  -- (_, toks) <- runM . runState (lowerBound @[Context]) $ runT (source (tokenizing src tagged) ~> machine fixingPipeline)
  -- pure (Sequence.fromList toks, tagged)

testAddKVPair' = do
  res <- translating (Proxy @'Language.JSON) . fst <$> testAddKVPair
  putStrLn (either show (show . typeset) res)

floatMatcher :: forall fs ann term . (Literal.Float :< fs, term ~ Term (Sum fs) ann)
             => Matcher term (Literal.Float term)
floatMatcher = matchM float target
  where float :: term -> Maybe (Literal.Float term)
        float = projectTerm

testFloatMatcher = do
  (src, tree) <- testJSONFile
  runMatcher floatMatcher tree

findFloats :: ( Apply Functor syntax
              , Apply Foldable syntax
              , Literal.Float :< syntax
              , term ~ Term (Sum syntax) ann
              )
           => Rule effs term (Either term (term, Literal.Float term))
findFloats = fromMatcher "test" floatMatcher

overwriteFloats :: forall effs syntax ann fields term . ( Apply Functor syntax
               , Apply Foldable syntax
               , Literal.Float :< syntax
               , ann ~ Record (History ': fields)
               , term ~ Term (Sum syntax) ann
               )
           => Rule effs (Either term (term, Literal.Float term)) term
overwriteFloats = fromPlan "overwritingFloats" $ do
  t <- await
  Data.Machine.yield (either id injFloat t)
  where injFloat :: (term, Literal.Float term) -> term
        injFloat (term, _) = remark Refactored (termIn (termAnnotation term) (inject (Literal.Float "0")))

testOverwriteFloats = do
  (src, tree) <- testJSONFile
  tagged <- runM $ {- ensureAccurateHistory <$> -} cata (toAlgebra (overwriteFloats . findFloats)) (markUnmodified tree)
  let toks = tokenizing src tagged
  pure (toks, tagged)

testOverwriteFloats' = do
  res <- translating (Proxy @'Language.JSON) . fst <$> testOverwriteFloats
  putStrLn (either show (show . typeset) res)

{-

             Hash
  term     /-------> refactor ------->\   term
--------->/                           |---------->
          \                          /
           \------> do nothing ----->/
             non-Hashes

-}


-- addKVPair :: forall fs fields .
--              (Apply Functor fs, Literal.Array :< fs, Literal.Hash :< fs, Literal.TextElement :< fs, Literal.KeyValue :< fs, Literal.Float :< fs)
--           => Term (Sum fs) (Record (History ': fields))
--           -> Term (Sum fs) (Record (History ': fields))
-- addKVPair p = case Sum.project (termOut p) of
--   Just (Literal.Hash h) -> termIn (Data.History.overwrite Modified (rhead (termAnnotation p)) :. rtail (annotation p)) (addToHash h)
--   Nothing -> Term (fmap addKVPair (unTerm p))
--   where
--     addToHash :: [Term (Sum fs) (Record (History : fields))] -> Sum fs (Term (Sum fs) (Record (History : fields)))
--     addToHash pairs = inject . Literal.Hash $ (pairs ++ [newItem])
--     newItem :: Term (Sum fs) (Record (History : fields))
--     newItem = termIn gen (inject (Literal.KeyValue fore aft))
--     fore = termIn gen (inject (Literal.TextElement "fore"))
--     aft = termIn gen (inject (Literal.TextElement "aft"))
--     gen = Generated :. rtail (annotation p)
--     item = inject (Literal.KeyValue (inject (Literal.TextElement "added")) (inject (Literal.Array [])))

testJSONFile = do
  let path = "test/fixtures/javascript/reprinting/map.json"
  src  <- blobSource <$> readBlobFromPath (File path Language.JSON)
  tree <- parseFile jsonParser path
  pure (src, tree)

testTokenizer = do
  (src, tree) <- testJSONFile

  let tagged = ensureAccurateHistory $ renameKey (markUnmodified tree)
  let toks = tokenizing src tagged
  pure (toks, tagged)

testTranslator = translating (Proxy @'Language.JSON) . fst <$> testTokenizer

testTypeSet = do
  res <- testTranslator
  putStrLn (either show (show . typeset) res)


-- Evaluate a project consisting of the listed paths.
evaluateProject proxy parser paths = withOptions debugOptions $ \ config logger statter ->
  evaluateProject' (TaskConfig config logger statter) proxy parser paths

data TaskConfig = TaskConfig Config LogQueue StatQueue

evaluateProject' (TaskConfig config logger statter) proxy parser paths = either (die . displayException) pure <=< runTaskWithConfig config logger statter $ do
  blobs <- catMaybes <$> traverse readFile (flip File (Language.reflect proxy) <$> paths)
  package <- fmap quieterm <$> parsePackage parser (Project (takeDirectory (maybe "/" fst (uncons paths))) blobs (Language.reflect proxy) [])
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  trace $ "evaluating with load order: " <> show (map (modulePath . moduleInfo) modules)
  pure (runTermEvaluator @_ @_ @(Value Precise UtilEff)
       (runReader (packageInfo package)
       (runReader (lowerBound @Span)
       (runReader (lowerBound @(ModuleTable (NonEmpty (Module (ModuleResult Precise)))))
       (raiseHandler (runModules (ModuleTable.modulePaths (packageModules package)))
       (evaluate proxy id withTermSpans (Precise.runAllocator . Precise.runDeref) (Concrete.runFunction coerce coerce) modules))))))


evaluateProjectWithCaching proxy parser path = runTaskWithOptions debugOptions $ do
  project <- readProject Nothing path (Language.reflect proxy) []
  package <- fmap quieterm <$> parsePackage parser project
  modules <- topologicalSort <$> runImportGraphToModules proxy package
  pure (runReader (packageInfo package)
       (runReader (lowerBound @Span)
       (runReader (lowerBound @(ModuleTable (NonEmpty (Module (ModuleResult Monovariant)))))
       (raiseHandler (runModules (ModuleTable.modulePaths (packageModules package)))
       (evaluate proxy id withTermSpans (Monovariant.runAllocator . Monovariant.runDeref) Type.runFunction modules)))))


parseFile :: Parser term -> FilePath -> IO term
parseFile parser = runTask . (parse parser <=< readBlob . file)

blob :: FilePath -> IO Blob
blob = runTask . readBlob . file


mergeExcs :: Either (SomeExc (Sum excs)) (Either (SomeExc exc) result) -> Either (SomeExc (Sum (exc ': excs))) result
mergeExcs = either (\ (SomeExc sum) -> Left (SomeExc (weaken sum))) (either (\ (SomeExc exc) -> Left (SomeExc (inject exc))) Right)

reassociate :: Either (SomeExc exc1) (Either (SomeExc exc2) (Either (SomeExc exc3) (Either (SomeExc exc4) (Either (SomeExc exc5) (Either (SomeExc exc6) (Either (SomeExc exc7) result)))))) -> Either (SomeExc (Sum '[exc7, exc6, exc5, exc4, exc3, exc2, exc1])) result
reassociate = mergeExcs . mergeExcs . mergeExcs . mergeExcs . mergeExcs . mergeExcs . mergeExcs . Right


prettyShow :: Show a => a -> IO ()
prettyShow = putStrLn . hscolour TTY defaultColourPrefs False False "" False . ppShow
