{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ViewPatterns #-}

module Language.Granule.Checker.Types where

import Control.Monad.State.Strict

import Language.Granule.Checker.Constraints.Compile

import Language.Granule.Checker.Effects
import Language.Granule.Checker.Kinds
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates
import Language.Granule.Checker.SubstitutionContexts
import Language.Granule.Checker.Substitution
import Language.Granule.Checker.Variables

import Language.Granule.Syntax.Helpers
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type

import Language.Granule.Utils

lEqualTypesWithPolarity :: (?globals :: Globals)
  => Span -> SpecIndicator ->Type -> Type -> Checker (Bool, Type, Substitution)
lEqualTypesWithPolarity s pol = equalTypesRelatedCoeffectsAndUnify s ApproximatedBy pol

equalTypesWithPolarity :: (?globals :: Globals)
  => Span -> SpecIndicator -> Type -> Type -> Checker (Bool, Type, Substitution)
equalTypesWithPolarity s pol = equalTypesRelatedCoeffectsAndUnify s Eq pol

lEqualTypes :: (?globals :: Globals)
  => Span -> Type -> Type -> Checker (Bool, Type, Substitution)
lEqualTypes s = equalTypesRelatedCoeffectsAndUnify s ApproximatedBy SndIsSpec

equalTypes :: (?globals :: Globals)
  => Span -> Type -> Type -> Checker (Bool, Type, Substitution)
equalTypes s = equalTypesRelatedCoeffectsAndUnify s Eq SndIsSpec

equalTypesWithUniversalSpecialisation :: (?globals :: Globals)
  => Span -> Type -> Type -> Checker (Bool, Type, Substitution)
equalTypesWithUniversalSpecialisation s = equalTypesRelatedCoeffectsAndUnify s Eq SndIsSpec

{- | Check whether two types are equal, and at the same time
     generate coeffect equality constraints and unify the
     two types

     The first argument is taken to be possibly approximated by the second
     e.g., the first argument is inferred, the second is a specification
     being checked against
-}
equalTypesRelatedCoeffectsAndUnify :: (?globals :: Globals)
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
  -- Starting spec indication
  -> SpecIndicator
  -- Left type (usually the inferred)
  -> Type
  -- Right type (usually the specified)
  -> Type
  -- Result is a effectful, producing:
  --    * a boolean of the equality
  --    * the most specialised type (after the unifier is applied)
  --    * the unifier
  -> Checker (Bool, Type, Substitution)
equalTypesRelatedCoeffectsAndUnify s rel spec t1 t2 = do

   (eq, unif) <- equalTypesRelatedCoeffects s rel t1 t2 spec
   if eq
     then do
        t2 <- substitute unif t2
        return (eq, t2, unif)
     else return (eq, t1, [])

data SpecIndicator = FstIsSpec | SndIsSpec | PatternCtxt
  deriving (Eq, Show)

flipIndicator :: SpecIndicator -> SpecIndicator
flipIndicator FstIsSpec = SndIsSpec
flipIndicator SndIsSpec = FstIsSpec
flipIndicator PatternCtxt = PatternCtxt

{- | Check whether two types are equal, and at the same time
     generate coeffect equality constraints and a unifier
      Polarity indicates which -}
equalTypesRelatedCoeffects :: (?globals :: Globals)
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
  -> Type
  -> Type
  -- Indicates whether the first type or second type is a specification
  -> SpecIndicator
  -> Checker (Bool, Substitution)
equalTypesRelatedCoeffects s rel t1 t2 sp = do
  -- Infer kinds
  k1 <- inferKindOfType s t1
  k2 <- inferKindOfType s t2
  -- Check the kinds are equal
  (eq, kind, unif) <- equalKinds s k1 k2
  -- If so, proceed with equality on types of this kind
  if eq
    then equalTypesRelatedCoeffectsInner s rel t1 t2 kind sp
    else
      -- Otherwise throw a kind error
      case sp of
        FstIsSpec -> throw $ KindMismatch { errLoc = s, tyActualK = Just t1, kExpected = k1, kActual = k2}
        _         -> throw $ KindMismatch { errLoc = s, tyActualK = Just t1, kExpected = k2, kActual = k1}

equalTypesRelatedCoeffectsInner :: (?globals :: Globals)
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
  -> Type
  -> Type
  -> Kind
  -- Indicates whether the first type or second type is a specification
  -> SpecIndicator
  -> Checker (Bool, Substitution)

equalTypesRelatedCoeffectsInner s rel fTy1@(FunTy t1 t2) fTy2@(FunTy t1' t2') _ sp = do
  -- contravariant position (always approximate)
  (eq1, u1) <-
    case sp of
      FstIsSpec -> equalTypesRelatedCoeffects s ApproximatedBy t1 t1' (flipIndicator sp)
      _         -> equalTypesRelatedCoeffects s ApproximatedBy t1' t1 (flipIndicator sp)
   -- covariant position (depends: is not always over approximated)
  t2 <- substitute u1 t2
  t2' <- substitute u1 t2'
  (eq2, u2) <- equalTypesRelatedCoeffects s rel t2 t2' sp
  unifiers <- combineSubstitutions s u1 u2
  return (eq1 && eq2, unifiers)

equalTypesRelatedCoeffectsInner _ _ (TyCon con1) (TyCon con2) _ _
  | internalName con1 /= "Pure" && internalName con2 /= "Pure" =
  return (con1 == con2, [])

equalTypesRelatedCoeffectsInner s rel (Diamond ef1 t1) (Diamond ef2 t2) _ sp = do
  (eq, unif) <- equalTypesRelatedCoeffects s rel t1 t2 sp
  (eq', unif') <- equalTypesRelatedCoeffects s rel ef1 ef2 sp
  u <- combineSubstitutions s unif unif'
  return (eq && eq', u)

equalTypesRelatedCoeffectsInner s rel x@(Box c t) y@(Box c' t') k sp = do
  -- Debugging messages
  debugM "equalTypesRelatedCoeffectsInner (pretty)" $ pretty c <> " == " <> pretty c'
  debugM "equalTypesRelatedCoeffectsInner (show)" $ "[ " <> show c <> " , " <> show c' <> "]"
  -- Unify the coeffect kinds of the two coeffects
  (kind, (inj1, inj2)) <- mguCoeffectTypes s c c'
  -- subst <- unify c c'

  -- Add constraint for the coeffect (using ^op for the ordering compared with the order of equality)
  addConstraint (rel s (inj2 c') (inj1 c) kind)

  equalTypesRelatedCoeffects s rel t t' sp
  --(eq, subst') <- equalTypesRelatedCoeffectsInner s rel uS t t' sp
  --case subst of
  --  Just subst -> do
--      substFinal <- combineSubstitutions s subst subst'
--      return (eq, substFinal)
  --  Nothing -> return (False, [])

equalTypesRelatedCoeffectsInner s _ (TyVar n) (TyVar m) _ _ | n == m = do
  checkerState <- get
  case lookup n (tyVarContext checkerState) of
    Just _ -> return (True, [])
    Nothing -> throw UnboundTypeVariable { errLoc = s, errId = n }

equalTypesRelatedCoeffectsInner s _ (TyVar n) (TyVar m) sp _ = do
  checkerState <- get
  debugM "variable equality" $ pretty n <> " ~ " <> pretty m <> " where "
                            <> pretty (lookup n (tyVarContext checkerState)) <> " and "
                            <> pretty (lookup m (tyVarContext checkerState))

  case (lookup n (tyVarContext checkerState), lookup m (tyVarContext checkerState)) of

    -- Two universally quantified variables are unequal
    (Just (_, ForallQ), Just (_, ForallQ)) ->
        return (False, [])

    -- We can unify a universal a dependently bound universal
    (Just (k1, ForallQ), Just (k2, BoundQ)) ->
      tyVarConstraint (k1, n) (k2, m)

    (Just (k1, BoundQ), Just (k2, ForallQ)) ->
      tyVarConstraint (k1, n) (k2, m)


    -- We can unify two instance type variables
    (Just (k1, InstanceQ), Just (k2, BoundQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (k1, BoundQ), Just (k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (k1, InstanceQ), Just (k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- We can unify two instance type variables
    (Just (k1, BoundQ), Just (k2, BoundQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- But we can unify a forall and an instance
    (Just (k1, InstanceQ), Just (k2, ForallQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    -- But we can unify a forall and an instance
    (Just (k1, ForallQ), Just (k2, InstanceQ)) ->
        tyVarConstraint (k1, n) (k2, m)

    (t1, t2) -> error $ pretty s <> "-" <> show sp <> "\n"
              <> pretty n <> " : " <> show t1
              <> "\n" <> pretty m <> " : " <> show t2
  where
    tyVarConstraint (k1, n) (k2, m) = do
      case k1 `joinKind` k2 of
        Just (KPromote (TyCon kc), unif) -> do

          k <- inferKindOfType s (TyCon kc)
          -- Create solver vars for coeffects
          if isCoeffectKind k
            then addConstraint (Eq s (CVar n) (CVar m) (TyCon kc))
            else return ()
          return (True, unif ++ [(n, SubstT $ TyVar m)])
        Just (_, unif) ->
          return (True, unif ++ [(m, SubstT $ TyVar n)])
        Nothing ->
          return (False, [])

-- Duality is idempotent (left)
equalTypesRelatedCoeffectsInner s rel (TyApp (TyCon d') (TyApp (TyCon d) t)) t' k sp
  | internalName d == "Dual" && internalName d' == "Dual" =
  equalTypesRelatedCoeffectsInner s rel t t' k sp

-- Duality is idempotent (right)
equalTypesRelatedCoeffectsInner s rel t (TyApp (TyCon d') (TyApp (TyCon d) t')) k sp
  | internalName d == "Dual" && internalName d' == "Dual" =
  equalTypesRelatedCoeffectsInner s rel t t' k sp

equalTypesRelatedCoeffectsInner s rel (TyVar n) t kind sp = do
  checkerState <- get
  debugM "Types.equalTypesRelatedCoeffectsInner on TyVar"
          $ "span: " <> show s
          <> "\nTyVar: " <> show n <> " with " <> show (lookup n (tyVarContext checkerState))
          <> "\ntype: " <> show t <> "\nspec indicator: " <> show sp

  -- Do an occurs check for types
  case kind of
    KType ->
       if n `elem` freeVars t
         then throw OccursCheckFail { errLoc = s, errVar = n, errTy = t }
         else return ()
    _ -> return ()

  case lookup n (tyVarContext checkerState) of
    -- We can unify an instance with a concrete type
    (Just (k1, q)) | (q == BoundQ) || (q == InstanceQ) -> do --  && sp /= PatternCtxt

      case k1 `joinKind` kind of
        Nothing -> throw UnificationKindError
          { errLoc = s, errTy1 = (TyVar n), errK1 = k1, errTy2 = t, errK2 = kind }

        -- If the kind is Nat, then create a solver constraint
        Just (KPromote (TyCon (internalName -> "Nat")), unif) -> do
          nat <- compileNatKindedTypeToCoeffect s t
          addConstraint (Eq s (CVar n) nat (TyCon $ mkId "Nat"))
          return (True, unif ++ [(n, SubstT t)])

        Just (_, unif) -> return (True, unif ++ [(n, SubstT t)])

    (Just (k1, ForallQ)) -> do

       -- If the kind if nat then set up and equation as there might be a
       -- pausible equation involving the quantified variable
       case k1 `joinKind` kind of
         Just (KPromote (TyCon (Id "Nat" "Nat")), unif) -> do
           c1 <- compileNatKindedTypeToCoeffect s (TyVar n)
           c2 <- compileNatKindedTypeToCoeffect s t
           addConstraint $ Eq s c1 c2 (TyCon $ mkId "Nat")
           return (True, unif ++ [(n, SubstT t)])

         _ -> throw UnificationFail{ errLoc = s, errVar = n, errKind = k1, errTy = t }

    (Just (_, InstanceQ)) -> error "Please open an issue at https://github.com/dorchard/granule/issues"
    (Just (_, BoundQ)) -> error "Please open an issue at https://github.com/dorchard/granule/issues"
    Nothing -> throw UnboundTypeVariable { errLoc = s, errId = n }


equalTypesRelatedCoeffectsInner s rel t (TyVar n) k sp =
  equalTypesRelatedCoeffectsInner s rel (TyVar n) t k (flipIndicator sp)

-- Do duality check (left) [special case of TyApp rule]
equalTypesRelatedCoeffectsInner s rel (TyApp (TyCon d) t) t' _ sp
  | internalName d == "Dual" = isDualSession s rel t t' sp

equalTypesRelatedCoeffectsInner s rel t (TyApp (TyCon d) t') _ sp
  | internalName d == "Dual" = isDualSession s rel t t' sp

-- Equality on type application
equalTypesRelatedCoeffectsInner s rel (TyApp t1 t2) (TyApp t1' t2') _ sp = do
  (one, u1) <- equalTypesRelatedCoeffects s rel t1 t1' sp
  t2  <- substitute u1 t2
  t2' <- substitute u1 t2'
  (two, u2) <- equalTypesRelatedCoeffects s rel t2 t2' sp
  unifiers <- combineSubstitutions s u1 u2
  return (one && two, unifiers)

equalTypesRelatedCoeffectsInner s rel t1 t2 k sp = do
  effTyM <- isEffectTypeFromKind s k
  case effTyM of
    Right effTy -> do
      -- If the kind of this equality is Effect
      -- then use effect equality (and possible approximation)
      eq <- effApproximates s effTy t1 t2
      return (eq, [])
    Left k ->
      -- Look to see if we are doing equality on sets that are not effects
      case (t1, t2) of
        -- If so do set equality (no approximation)
        (TySet ts1, TySet ts2) ->
          return (all (`elem` ts2) ts1 && all (`elem` ts1) ts2, [])

        -- Otherwise look at other equalities
        _ -> equalOtherKindedTypesGeneric s t1 t2 k

{- | Equality on other types (e.g. Nat and Session members) -}
equalOtherKindedTypesGeneric :: (?globals :: Globals)
    => Span
    -> Type
    -> Type
    -> Kind
    -> Checker (Bool, Substitution)
equalOtherKindedTypesGeneric s t1 t2 k = do
  case k of
    KPromote (TyCon (internalName -> "Nat")) -> do
      c1 <- compileNatKindedTypeToCoeffect s t1
      c2 <- compileNatKindedTypeToCoeffect s t2
      addConstraint $ Eq s c1 c2 (TyCon $ mkId "Nat")
      return (True, [])

    KPromote (TyCon (internalName -> "Protocol")) ->
      sessionInequality s t1 t2

    KType -> throw UnificationError{ errLoc = s, errTy1 = t1, errTy2 = t2}

    _ ->
      throw UndefinedEqualityKindError
        { errLoc = s, errTy1 = t1, errK1 = k, errTy2 = t2, errK2 = k }

-- Essentially use to report better error messages when two session type
-- are not equality
sessionInequality :: (?globals :: Globals)
    => Span -> Type -> Type -> Checker (Bool, Substitution)
sessionInequality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Send" && internalName c' == "Send" = do
  (g, _, u) <- equalTypes s t t'
  return (g, u)

sessionInequality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Recv" && internalName c' == "Recv" = do
  (g, _, u) <- equalTypes s t t'
  return (g, u)

sessionInequality s (TyCon c) (TyCon c')
  | internalName c == "End" && internalName c' == "End" =
  return (True, [])

sessionInequality s t1 t2 = throw TypeError{ errLoc = s, tyExpected = t1, tyActual = t2 }

isDualSession :: (?globals :: Globals)
    => Span
       -- Explain how coeffects should be related by a solver constraint
    -> (Span -> Coeffect -> Coeffect -> Type -> Constraint)
    -> Type
    -> Type
    -- Indicates whether the first type or second type is a specification
    -> SpecIndicator
    -> Checker (Bool, Substitution)
isDualSession sp rel (TyApp (TyApp (TyCon c) t) s) (TyApp (TyApp (TyCon c') t') s') ind
  |  (internalName c == "Send" && internalName c' == "Recv")
  || (internalName c == "Recv" && internalName c' == "Send") = do
  (eq1, u1) <- equalTypesRelatedCoeffects sp rel t t' ind
  (eq2, u2) <- isDualSession sp rel s s' ind
  u <- combineSubstitutions sp u1 u2
  return (eq1 && eq2, u)

isDualSession _ _ (TyCon c) (TyCon c') _
  | internalName c == "End" && internalName c' == "End" =
  return (True, [])

isDualSession sp rel t (TyVar v) ind =
  equalTypesRelatedCoeffects sp rel (TyApp (TyCon $ mkId "Dual") t) (TyVar v) ind

isDualSession sp rel (TyVar v) t ind =
  equalTypesRelatedCoeffects sp rel (TyVar v) (TyApp (TyCon $ mkId "Dual") t) ind

isDualSession sp _ t1 t2 _ = throw
  SessionDualityError{ errLoc = sp, errTy1 = t1, errTy2 = t2 }


-- Essentially equality on types but join on any coeffects
joinTypes :: (?globals :: Globals) => Span -> Type -> Type -> Checker Type
joinTypes s t t' | t == t' = return t

joinTypes s (FunTy t1 t2) (FunTy t1' t2') = do
  t1j <- joinTypes s t1' t1 -- contravariance
  t2j <- joinTypes s t2 t2'
  return (FunTy t1j t2j)

joinTypes _ (TyCon t) (TyCon t') | t == t' = return (TyCon t)

joinTypes s (Diamond ef t) (Diamond ef' t') = do
  tj <- joinTypes s t t'
  ej <- joinTypes s ef ef'
  return (Diamond ej tj)

joinTypes s (Box c t) (Box c' t') = do
  (coeffTy, (inj1, inj2)) <- mguCoeffectTypes s c c'
  -- Create a fresh coeffect variable
  topVar <- freshTyVarInContext (mkId "") (promoteTypeToKind coeffTy)
  -- Unify the two coeffects into one
  addConstraint (ApproximatedBy s (inj1 c)  (CVar topVar) coeffTy)
  addConstraint (ApproximatedBy s (inj2 c') (CVar topVar) coeffTy)
  tUpper <- joinTypes s t t'
  return $ Box (CVar topVar) tUpper

joinTypes s (TyInt n) (TyVar m) = do
  -- Create a fresh coeffect variable
  let ty = TyCon $ mkId "Nat"
  var <- freshTyVarInContext m (KPromote ty)
  -- Unify the two coeffects into one
  addConstraint (Eq s (CNat n) (CVar var) ty)
  return $ TyInt n

joinTypes s (TyVar n) (TyInt m) = joinTypes s (TyInt m) (TyVar n)

joinTypes s (TyVar n) (TyVar m) = do

  kind <- inferKindOfType s (TyVar n)
  case kind of
    KPromote t -> do

      nvar <- freshTyVarInContextWithBinding n kind BoundQ
      -- Unify the two variables into one
      addConstraint (ApproximatedBy s (CVar n) (CVar nvar) t)
      addConstraint (ApproximatedBy s (CVar m) (CVar nvar) t)
      return $ TyVar nvar

    _ -> error $ "Trying to join two type variables: " ++ pretty n ++ " and " ++ pretty m

joinTypes s (TyApp t1 t2) (TyApp t1' t2') = do
  t1'' <- joinTypes s t1 t1'
  t2'' <- joinTypes s t2 t2'
  return (TyApp t1'' t2'')

-- TODO: Create proper substitutions
joinTypes s (TyVar _) t = return t
joinTypes s t (TyVar _) = return t

joinTypes s t1 t2 = do
    -- See if the two types are actually effects and if so do the join
    mefTy1 <- isEffectType s t1
    mefTy2 <- isEffectType s t2
    case mefTy1 of
        Right efTy1 ->
          case mefTy2 of
            Right efTy2 -> do
                -- Check that the types of the effect terms match
                (eq, _, u) <- equalTypes s efTy1 efTy2
                -- If equal, do the upper bound
                if eq
                    then do effectUpperBound s efTy1 t1 t2
                    else throw $ KindMismatch { errLoc = s, tyActualK = Just t1, kExpected = KPromote efTy1, kActual = KPromote efTy2 }
            Left _ -> throw $ NoUpperBoundError{ errLoc = s, errTy1 = t1, errTy2 = t2 }
        Left _ -> throw $ NoUpperBoundError{ errLoc = s, errTy1 = t1, errTy2 = t2 }

-- TODO: eventually merge this with joinKind
equalKinds :: (?globals :: Globals) => Span -> Kind -> Kind -> Checker (Bool, Kind, Substitution)
equalKinds sp k1 k2 | k1 == k2 = return (True, k1, [])
equalKinds sp (KPromote t1) (KPromote t2) = do
    (eq, t, u) <- equalTypes sp t1 t2
    return (eq, KPromote t, u)
equalKinds sp (KFun k1 k1') (KFun k2 k2') = do
    (eq, k, u) <- equalKinds sp k1 k2
    (eq', k', u') <- equalKinds sp k1' k2'
    u2 <- combineSubstitutions sp u u'
    return $ (eq && eq', KFun k k', u2)
equalKinds sp (KVar v) k = do
    return (True, k, [(v, SubstK k)])
equalKinds sp k (KVar v) = do
    return (True, k, [(v, SubstK k)])
equalKinds sp k1 k2 = do
    case joinKind k1 k2 of
      Just (k, u) -> return (True, k, u)
      Nothing -> throw $ KindsNotEqual { errLoc = sp, errK1 = k1, errK2 = k2 }

twoEqualEffectTypes :: (?globals :: Globals) => Span -> Type -> Type -> Checker (Type, Substitution)
twoEqualEffectTypes s ef1 ef2 = do
    mefTy1 <- isEffectType s ef1
    mefTy2 <- isEffectType s ef2
    case mefTy1 of
      Right efTy1 ->
        case mefTy2 of
          Right efTy2 -> do
            -- Check that the types of the effect terms match
            (eq, _, u) <- equalTypes s efTy1 efTy2
            if eq then do
              return (efTy1, u)
            else throw $ KindMismatch { errLoc = s, tyActualK = Just ef1, kExpected = KPromote efTy1, kActual = KPromote efTy2 }
          Left k -> throw $ UnknownResourceAlgebra { errLoc = s, errTy = ef2 , errK = k }
      Left k -> throw $ UnknownResourceAlgebra { errLoc = s, errTy = ef1 , errK = k }