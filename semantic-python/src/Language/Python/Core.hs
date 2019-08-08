{-# LANGUAGE DefaultSignatures, DeriveGeneric, FlexibleContexts, FlexibleInstances, RecordWildCards, StandaloneDeriving, TypeOperators, NamedFieldPuns #-}
module Language.Python.Core
( compile
) where

import           Control.Monad.Fail
import           Data.Core as Core
import           Data.Name as Name
import           Data.Term
import           GHC.Generics
import           Prelude hiding (fail)
import qualified TreeSitter.Python.AST as Py

class Compile t where
  -- FIXME: we should really try not to fail
  compile :: MonadFail m => t -> m (Term Core Name)
  default compile :: (MonadFail m, Show t) => t -> m (Term Core Name)
  compile = defaultCompile

defaultCompile :: (MonadFail m, Show t) => t -> m (Term Core Name)
defaultCompile t = fail $ "compilation unimplemented for " <> show t

instance (Compile l, Compile r) => Compile (Either l r) where compile = compileSum

instance Compile Py.AssertStatement
instance Compile Py.Attribute
instance Compile Py.Await
instance Compile Py.BinaryOperator
instance Compile Py.Block
instance Compile Py.BooleanOperator
instance Compile Py.BreakStatement
instance Compile Py.Call
instance Compile Py.ClassDefinition
instance Compile Py.ComparisonOperator

instance Compile Py.CompoundStatement where compile = compileSum

instance Compile Py.ConcatenatedString
instance Compile Py.ConditionalExpression
instance Compile Py.ContinueStatement
instance Compile Py.DecoratedDefinition
instance Compile Py.DeleteStatement
instance Compile Py.Dictionary
instance Compile Py.DictionaryComprehension
instance Compile Py.Ellipsis
instance Compile Py.ExecStatement

instance Compile Py.Expression where compile = compileSum

instance Compile Py.ExpressionStatement

instance Compile Py.False where compile _ = pure (Core.bool False)

instance Compile Py.Float
instance Compile Py.ForStatement

instance Compile Py.FunctionDefinition where
  compile Py.FunctionDefinition
    { name       = Py.Identifier name
    , parameters = Py.Parameters parameters
    , body
    } = do
      names <- paramNames
      let binders = fmap (\n -> (Name.namedName n, Core.unit)) names
      body' <- compile body
      pure ((Name.named' name) :<- (Core.record binders) >>>= Core.lams names body')
    where paramNames = case parameters of
            Nothing -> pure []
            Just p  -> traverse param [p] -- FIXME: this is wrong in node-types.json, @p@ should already be a list
          param (Right (Right (Right (Left (Py.Identifier name))))) = pure (Name.named' name)
          param x = unimplemented x
          unimplemented x = fail $ "unimplemented: " <> show x

instance Compile Py.FutureImportStatement
instance Compile Py.GeneratorExpression
instance Compile Py.GlobalStatement

instance Compile Py.Identifier where
  compile (Py.Identifier text) = pure (Var text)

instance Compile Py.IfStatement where
  compile Py.IfStatement{alternative, consequence, condition}
    = Core.if' <$> compile condition <*> compile consequence <*> foldr clause (pure Core.unit) alternative
    where clause (Left  Py.ElifClause{..}) rest = Core.if' <$> compile condition <*> compile consequence <*> rest
          clause (Right Py.ElseClause{..}) _    = compile body

instance Compile Py.ImportFromStatement
instance Compile Py.ImportStatement
instance Compile Py.Integer
instance Compile Py.Lambda
instance Compile Py.List
instance Compile Py.ListComprehension

instance Compile Py.Module where
  compile (Py.Module statements) = do' . fmap (Nothing :<-) <$> traverse compile statements

instance Compile Py.NamedExpression
instance Compile Py.None
instance Compile Py.NonlocalStatement
instance Compile Py.NotOperator
instance Compile Py.ParenthesizedExpression
instance Compile Py.PassStatement

instance Compile Py.PrimaryExpression where compile = compileSum

instance Compile Py.PrintStatement
instance Compile Py.ReturnStatement
instance Compile Py.RaiseStatement
instance Compile Py.Set
instance Compile Py.SetComprehension

instance Compile Py.SimpleStatement where compile = compileSum

instance Compile Py.String
instance Compile Py.Subscript

instance Compile Py.True where compile _ = pure $ Core.bool True

instance Compile Py.TryStatement
instance Compile Py.Tuple
instance Compile Py.UnaryOperator
instance Compile Py.WhileStatement
instance Compile Py.WithStatement


compileSum :: (Generic t, GCompileSum (Rep t), MonadFail m) => t -> m (Term Core Name)
compileSum = gcompileSum . from

class GCompileSum f where
  gcompileSum :: MonadFail m => f a -> m (Term Core Name)

instance GCompileSum f => GCompileSum (M1 D d f) where
  gcompileSum (M1 f) = gcompileSum f

instance (GCompileSum l, GCompileSum r) => GCompileSum (l :+: r) where
  gcompileSum (L1 l) = gcompileSum l
  gcompileSum (R1 r) = gcompileSum r

instance Compile t => GCompileSum (M1 C c (M1 S s (K1 R t))) where
  gcompileSum (M1 (M1 (K1 t))) = compile t
