{- pi-forall -}

-- | The main routines for type-checking
module TypeCheck (tcModules, inferType, checkType) where

import Control.Monad.Except
import Data.Maybe (catMaybes)
import Debug.Trace
import Environment (D (..), TcMonad)
import Environment qualified as Env
import Equal qualified
import PrettyPrint (Disp (disp))
import Syntax
import Text.PrettyPrint.HughesPJ (render, ($$))
import Unbound.Generics.LocallyNameless qualified as Unbound
import Unbound.Generics.LocallyNameless.Internal.Fold qualified as Unbound

-- | Infer/synthesize the type of a term
inferType :: Term -> TcMonad Type
inferType t = tcTerm t Nothing

-- | Check that the given term has the expected type
checkType :: Term -> Type -> TcMonad ()
checkType tm (Pos _ ty) = checkType tm ty -- ignore source positions/annotations
checkType tm (Ann ty _) = checkType tm ty
checkType tm ty = void $ tcTerm tm (Just ty)

-- | Make sure that the term is a "type" (i.e. that it has type 'Type')
tcType :: Term -> TcMonad ()
tcType tm = void $ checkType tm Type

---------------------------------------------------------------------

-- | Combined type checking/inference function
-- The second argument is 'Just expectedType' in checking mode and 'Nothing' in inference mode
-- In either case, this function returns the type of the term
tcTerm :: Term -> Maybe Type -> TcMonad Type
-- i-var
tcTerm t@(Var x) Nothing = do
  sig <- Env.lookupTy x
  return (sigType sig)
-- i-type
tcTerm Type Nothing = return Type
-- i-pi
tcTerm (Pi tyA bnd) Nothing = do
  (x, tyB) <- Unbound.unbind bnd
  tcType tyA
  Env.extendCtx (mkSig x tyA) (tcType tyB)
  return Type
-- c-lam: check the type of a function
tcTerm (Lam bnd) (Just (Pi tyA bnd2)) = do
  -- unbind the variables in the lambda expression and pi type
  (x, body, _, tyB) <- Unbound.unbind2Plus bnd bnd2

  -- check the type of the body of the lambda expression
  Env.extendCtx (mkSig x tyA) (checkType body tyB)
  return (Pi tyA bnd2)
tcTerm (Lam _) (Just nf) =
  Env.err [DS "Lambda expression should have a function type, not", DD nf]
-- i-app
tcTerm (App t1 t2) Nothing = do
  ty1 <- inferType t1
  let ensurePi :: Type -> TcMonad (Type, Unbound.Bind TName Type)
      ensurePi (Ann a _) = ensurePi a
      ensurePi (Pos _ a) = ensurePi a
      ensurePi (Pi tyA bnd) = return (tyA, bnd)
      ensurePi ty = Env.err [DS "Expected a function type but found ", DD ty]
  (tyA, bnd) <- ensurePi ty1
  checkType t2 tyA
  return (Unbound.instantiate bnd [t2])

-- i-ann
tcTerm (Ann tm ty) Nothing = do
  tcType ty
  checkType tm ty
  return ty

-- practicalities
-- remember the current position in the type checking monad
tcTerm (Pos p tm) mTy =
  Env.extendSourceLocation p tm $ tcTerm tm mTy
-- ignore term, just return type annotation
tcTerm TrustMe (Just ty) = return ty
-- i-unit
tcTerm TyUnit Nothing = return Type
tcTerm LitUnit Nothing = return TyUnit
-- i-bool
tcTerm TyBool Nothing = return Type -- Env.err [DS "unimplemented"]
-- i-true/false
tcTerm (LitBool b) Nothing = return TyBool -- Env.err [DS "unimplemented"]
-- c-if
tcTerm t@(If t1 t2 t3) (Just ty) = do
  ty1 <- inferType t1 
  ty2 <- inferType t2
  ty3 <- inferType t3
  unless (Unbound.aeq ty2 ty3) $ Env.err [DS "True and False clause don't match", DD ty2, DS "and", DD ty3]
  unless (Unbound.aeq ty2 ty) $ Env.err [DS "True clause has wrong type", DD ty2, DS "and", DD ty]
  unless (Unbound.aeq ty3 ty) $ Env.err [DS "False clause has wrong type", DD ty3, DS "and", DD ty]
  -- TODO: Add to the context the knowledge that in t2, t1 is (LitBool true), and in t3, t1 is (LitBool False)
  case ty1 of
    TyBool -> return ty2 
    _ -> Env.err [DS ("Conditional must be Bool, got: " ++ (show ty1))] -- Env.err [DS "Conditional must be a Bool"] -- Env.err [DS "unimplemented"]
-- i-if
tcTerm t@(If t1 t2 t3) Nothing = do
  ty1 <- inferType t1 
  ty2 <- inferType t2
  ty3 <- inferType t3
  unless (Unbound.aeq ty2 ty3) $ Env.err [DS "True and False clause don't match", DD ty2, DS "and", DD ty3]
  case ty1 of
    TyBool -> return ty2 
    _ -> Env.err [DS ("Conditional must be Bool, got: " ++ (show ty1))] -- Env.err [DS "Conditional must be a Bool"] -- Env.err [DS "unimplemented"]

-- c-let and i-let
-- Key question here: wtf are these vars actually
tcTerm (Let rhs bnd) mty = do 
  tcType rhs
  (x, tyB) <- Unbound.unbind bnd
  Env.err [DS "unimplemented Let", DD rhs, DS "and", DD tyB]

-- i-sigma
tcTerm t@(Sigma tyA bnd) Nothing = do 
  (x, tyB) <- Unbound.unbind bnd
  checkType tyA Type
  Env.extendCtx (mkSig x tyA) $ checkType tyB Type
  -- Env.err [DS "unimplemented aaaah Sigma", DD tyA, DS "and", DS (show tyB)]
  case tyB of
    Pos p tm -> do 
      return Type --(Sigma tyA (Unbound.bind x tyB))
    _ -> Env.err [DS "unimplemented _ Sigma", DD tyA, DS "and", DS (show tyB)]
  --return (Sigma tyA tyC)
  --Env.err [DS "unimplemented Sigma", DD tyA, DS "and", DS (show res)]

-- c-prod
tcTerm t@(Prod a b) (Just ty) = case ty of 
  Sigma tyA bnd -> do --Env.err [DS "unimplemented Prod for Sigma"]
    checkType a tyA
    (x, tyB) <- Unbound.unbind bnd
    checkType b tyB
    return (Sigma tyA (Unbound.bind x tyB))
  _ -> Env.err [DS "unimplemented Prod for non-Sigma"]
tcTerm t@(LetPair p bnd) (Just ty) = do 
    (x, tyB) <- Unbound.unbind bnd
    tcType ty
    Env.err [DS "unimplemented LetPair"]
tcTerm PrintMe (Just ty) = do
  gamma <- Env.getLocalCtx
  Env.warn
    [ DS "Unmet obligation.\nContext:",
      DD gamma,
      DS "\nGoal:",
      DD ty
    ]
  return ty

-- c-infer
tcTerm tm (Just ty) = do
  ty' <- inferType tm
  unless (Unbound.aeq ty' ty) $ Env.err [DS "Types don't match", DD ty, DS "and", DD ty']
  return ty'
tcTerm tm Nothing =
  Env.err [DS "Must have a type annotation to check", DD tm]

--------------------------------------------------------
-- Using the typechecker for decls and modules and stuff
--------------------------------------------------------

-- | Typecheck a collection of modules. Assumes that each module
-- appears after its dependencies. Returns the same list of modules
-- with each definition typechecked
tcModules :: [Module] -> TcMonad [Module]
tcModules = foldM tcM []
  where
    -- Check module m against modules in defs, then add m to the list.
    defs `tcM` m = do
      -- "M" is for "Module" not "monad"
      let name = moduleName m
      liftIO $ putStrLn $ "Checking module " ++ show name
      m' <- defs `tcModule` m
      return $ defs ++ [m']

-- | Typecheck an entire module.
tcModule ::
  -- | List of already checked modules (including their Decls).
  [Module] ->
  -- | Module to check.
  Module ->
  -- | The same module with all Decls checked and elaborated.
  TcMonad Module
tcModule defs m' = do
  checkedEntries <-
    Env.extendCtxMods importedModules $
      foldr
        tcE
        (return [])
        (moduleEntries m')
  return $ m' {moduleEntries = checkedEntries}
  where
    d `tcE` m = do
      -- Extend the Env per the current Decl before checking
      -- subsequent Decls.
      x <- tcEntry d
      case x of
        AddHint hint -> Env.extendHints hint m
        -- Add decls to the Decls to be returned
        AddCtx decls -> (decls ++) <$> Env.extendCtxsGlobal decls m
    -- Get all of the defs from imported modules (this is the env to check current module in)
    importedModules = filter (\x -> ModuleImport (moduleName x) `elem` moduleImports m') defs

-- | The Env-delta returned when type-checking a top-level Decl.
data HintOrCtx
  = AddHint Sig
  | AddCtx [Decl]

-- | Check each sort of declaration in a module
tcEntry :: Decl -> TcMonad HintOrCtx
tcEntry (Def n term) = do
  oldDef <- Env.lookupDef n
  maybe tc die oldDef
  where
    tc = do
      lkup <- Env.lookupHint n
      case lkup of
        Nothing -> do
          ty <- inferType term
          return $ AddCtx [TypeSig (Sig n ty), Def n term]
        Just sig ->
          let handler (Env.Err ps msg) = throwError $ Env.Err ps (msg $$ msg')
              msg' =
                disp
                  [ DS "When checking the term",
                    DD term,
                    DS "against the signature",
                    DD sig
                  ]
           in do
                Env.extendCtx (TypeSig sig) $ checkType term (sigType sig) `catchError` handler
                if n `elem` Unbound.toListOf Unbound.fv term
                  then return $ AddCtx [TypeSig sig, RecDef n term]
                  else return $ AddCtx [TypeSig sig, Def n term]
    die term' =
      Env.extendSourceLocation (unPosFlaky term) term $
        Env.err
          [ DS "Multiple definitions of",
            DD n,
            DS "Previous definition was",
            DD term'
          ]
tcEntry (TypeSig sig) = do
  duplicateTypeBindingCheck sig
  tcType (sigType sig)
  return $ AddHint sig
tcEntry _ = Env.err "unimplemented"

-- | Make sure that we don't have the same name twice in the
-- environment. (We don't rename top-level module definitions.)
duplicateTypeBindingCheck :: Sig -> TcMonad ()
duplicateTypeBindingCheck sig = do
  -- Look for existing type bindings ...
  let n = sigName sig
  l <- Env.lookupTyMaybe n
  l' <- Env.lookupHint n
  -- ... we don't care which, if either are Just.
  case catMaybes [l, l'] of
    [] -> return ()
    -- We already have a type in the environment so fail.
    sig' : _ ->
      let (Pos p _) = sigType sig
          msg =
            [ DS "Duplicate type signature",
              DD sig,
              DS "Previous was",
              DD sig'
            ]
       in Env.extendSourceLocation p sig $ Env.err msg
