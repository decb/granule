-- Pretty printer for Granule
--  It is not especially pretty.
-- Useful in debugging and error messages

{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE UndecidableInstances #-}

module Language.Granule.Syntax.Pretty where

import Data.List
import Language.Granule.Syntax.Expr
import Language.Granule.Syntax.Type
import Language.Granule.Syntax.Pattern
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Def
import Language.Granule.Syntax.Identifiers
import Language.Granule.Utils

prettyDebug :: (?globals :: Globals) => Pretty t => t -> String
prettyDebug x =
  let ?globals = ?globals { debugging = True }
  in prettyL 0 x

pretty :: (?globals :: Globals, Pretty t) => t -> String
pretty = prettyL 0

type Level = Int

parens :: Level -> String -> String
parens l x | l <= 0 = x
parens n x =
  if head x == '(' && last x == ')'
    then x
    else "(" <> x <> ")"

-- The pretty printer class
class Pretty t where
    -- `prettyL l` pretty printers something at nesting level `l`
    prettyL :: (?globals :: Globals) => Level -> t -> String

-- Mostly for debugging

instance {-# OVERLAPPABLE #-} (Pretty a, Pretty b) => Pretty (a, b) where
   prettyL l (a, b) = "(" <> prettyL l a <> ", " <> prettyL l b <> ")"

instance {-# OVERLAPPABLE #-} (Pretty a, Pretty b, Pretty c) => Pretty (a, b,c) where
   prettyL l (a, b, c) = "(" <> prettyL l a <> ", " <> prettyL l b <> "," <> prettyL l c <> ")"

instance {-# OVERLAPS #-} Pretty String where
   prettyL l s = s

instance Pretty () where
   prettyL l () = ""

instance {-# OVERLAPPABLE #-} Pretty a => Pretty [a] where
   prettyL l xs = "[" <> intercalate "," (map (prettyL l) xs) <> "]"

-- Core prettyL l printers

instance {-# OVERLAPS #-} Pretty Effect where
   prettyL l es = "[" <> intercalate "," es <> "]"

instance Pretty Coeffect where
    prettyL l (CNat n) = show n
    prettyL l (CFloat n) = show n
    prettyL l (COne k)  = "_1 : " <> prettyL l k
    prettyL l (CZero k) = "_0 : " <> prettyL l k
    prettyL l (Level 0) = "Public"
    prettyL l (Level _) = "Private"
    prettyL l (CExpon a b) = prettyL l a <> "^" <> prettyL l b
    prettyL l (CVar c) = prettyL l c
    prettyL l (CMeet c d) =
      prettyL l c <> " /\\ " <> prettyL l d
    prettyL l (CJoin c d) =
      prettyL l c <> " \\/ " <> prettyL l d
    prettyL l (CPlus c d) =
      prettyL l c <> " + " <> prettyL l d
    prettyL l (CTimes c d) =
      prettyL l c <> " * " <> prettyL l d
    prettyL l (CSet xs) =
      "{" <> intercalate "," (map (\(name, t) -> name <> " : " <> prettyL l t) xs) <> "}"
    prettyL l (CSig c t) =
       parens l (prettyL (l+1) c <> " : " <> prettyL l t)

    prettyL l (CInfinity k) = "∞ : " <> prettyL l k
    prettyL l (CInterval c1 c2) = prettyL l c1 <> ".." <> prettyL l c2
    prettyL l (CProduct c1 c2) = "(" <> prettyL l c1 <> " * " <> prettyL l c2 <> ")"

instance Pretty Kind where
    prettyL l KType          = "Type"
    prettyL l KCoeffect      = "Coeffect"
    prettyL l (KFun k1 k2)   = prettyL l k1 <> " -> " <> prettyL l k2
    prettyL l (KVar v)       = prettyL l v
    prettyL l (KPromote t)   = "↑" <> prettyL l t

instance Pretty TypeScheme where
    prettyL l (Forall _ [] t) = prettyL l t
    prettyL l (Forall _ cvs t) =
        "forall " <> intercalate ", " (map prettyKindSignatures cvs) <> ". " <> prettyL l t
      where
       prettyKindSignatures (var, kind) = prettyL l var <> " : " <> prettyL l kind

instance Pretty Type where
    -- Atoms
    prettyL l (TyCon s)      =  prettyL 0 s
    prettyL l (TyVar v)      = prettyL 0 v
    prettyL l (TyInt n)      = show n

    -- Non atoms
    prettyL l (FunTy t1 t2)  =
      parens l $ case t1 of
        FunTy{} -> prettyL (l+1) t1 <> " -> " <> prettyL l t2
        _       ->  prettyL l t1 <> " -> " <> prettyL l t2

    prettyL l (Box c t)      =
       parens l (prettyL (l+1) t <> " [" <> prettyL l c <> "]")

    prettyL l (Diamond e t) | e == ["Com"] =
      parens l ("Session " <> prettyL (l+1) t)

    prettyL l (Diamond e t)  =
       parens l (prettyL (l+1) t <> " <" <> prettyL l e <> ">")

    prettyL l (TyApp (TyApp (TyCon x) t1) t2) | sourceName x == "(,)" =
      parens l ("(" <> prettyL l t1 <> ", " <> prettyL l t2 <> ")")

    prettyL l (TyApp (TyApp (TyCon x) t1) t2) | sourceName x == "(*)" =
      parens l ("(" <> prettyL l t1 <> " * " <> prettyL l t2 <> ")")

    prettyL l t@(TyApp (TyApp _ _) _) | appChain t =
      parens l tyAppPretty
        where
          tyAppPretty = intercalate " " (map (prettyL (l+1)) (flatten t))
          flatten (TyApp t1 t2) = flatten t1 ++ [t2]
          flatten t = [t]

    prettyL l (TyApp t1 t2)  =
      parens l (prettyL l t1 <> " " <> prettyL (l+1) t2)

    prettyL l (TyInfix op t1 t2) =
      parens l (prettyL (l+1) t1 <> " " <> op <> " " <>  prettyL (l+1) t2)

appChain :: Type -> Bool
appChain (TyApp (TyApp t1 t2) _) = appChain (TyApp t1 t2)
appChain (TyApp t1 t2)           = True
appChain _                       = False

instance (Pretty (Value v a), Pretty v) => Pretty (AST v a) where
    prettyL l (AST dataDecls defs) = pretty' dataDecls <> "\n\n" <> pretty' defs
      where
        pretty' :: Pretty l => [l] -> String
        pretty' = intercalate "\n\n" . map pretty

instance (Pretty (Value v a), Pretty v) => Pretty (Def v a) where
    prettyL l (Def _ v eqs t) =
        prettyL l v <> " : " <> prettyL l t <> "\n"
                    <> intercalate "\n" (map prettyEq eqs)
      where
        prettyEq (Equation _ _ ps e) =
          prettyL l v <> " " <> prettyL l ps <> "= " <> prettyL l e

instance Pretty DataDecl where
    prettyL l (DataDecl _ tyCon tyVars kind dataConstrs) =
      let tvs = case tyVars of [] -> ""; _ -> (unwords . map pretty) tyVars <> " "
          ki = case kind of Nothing -> ""; Just k -> prettyL l k <> " "
      in "data " <> prettyL l tyCon <> " " <> tvs <> ki <> "where\n  " <> prettyL l dataConstrs

instance Pretty [DataConstr] where
    prettyL l = intercalate ";\n  " . map pretty

instance Pretty DataConstr where
    prettyL l (DataConstrG _ name typeScheme) = prettyL l name <> " : " <> prettyL l typeScheme
    prettyL l (DataConstrA _ name params) = prettyL l name <> (unwords . map (prettyL l)) params

instance Pretty (Pattern a) where
    prettyL l (PVar _ _ v)     = prettyL l v
    prettyL l (PWild _ _)      = "_"
    prettyL l (PBox _ _ p)     = "[" <> prettyL l p <> "]"
    prettyL l (PInt _ _ n)     = show n
    prettyL l (PFloat _ _ n)   = show n
    prettyL l (PConstr _ _ name args)  = intercalate " " (prettyL l name : map (prettyL l) args)

instance {-# OVERLAPS #-} Pretty [Pattern a] where
    prettyL l [] = ""
    prettyL l ps = unwords (map (prettyL l) ps) <> " "

instance Pretty t => Pretty (Maybe t) where
    prettyL l Nothing = "unknown"
    prettyL l (Just x) = prettyL l x

instance Pretty v => Pretty (Value v a) where
    prettyL l (Abs _ x t e)  = parens l $ "\\(" <> prettyL l x <> " : " <> prettyL l t
                               <> ") -> " <> prettyL l e
    prettyL l (Promote _ e)  = "[" <> prettyL l e <> "]"
    prettyL l (Pure _ e)     = "<" <> prettyL l e <> ">"
    prettyL l (Var _ x)      = prettyL 0 x
    prettyL l (NumInt n)   = show n
    prettyL l (NumFloat n) = show n
    prettyL l (CharLiteral c) = show c
    prettyL l (StringLiteral s) = show s
    prettyL l (Constr _ s vs) | internalName s == "," =
      "(" <> intercalate ", " (map (prettyL l) vs) <> ")"
    prettyL l (Constr _ n []) = prettyL 0 n
    prettyL l (Constr _ n vs) = intercalate " " (prettyL l n : map (parensOn (not . valueAtom)) vs)
      where
        -- Syntactically atomic values
        valueAtom (NumInt _)    = True
        valueAtom (NumFloat _)  = True
        valueAtom (Constr _ _ []) = True
        valueAtom _             = False
    prettyL l (Ext _ v) = prettyL l v

instance Pretty Id where
  prettyL l
    = if debugging ?globals
        then internalName
        else takeWhile (\c -> c /= '.' && c /= '`') . sourceName

instance Pretty (Value v a) => Pretty (Expr v a) where
  prettyL l (App _ _ e1 e2) =
    parens l $ prettyL (l+1) e1 <> " " <> prettyL l e2

  prettyL l (Binop _ _ op e1 e2) =
    parens l $ prettyL (l+1) e1 <> " " <> op <> " " <> prettyL (l+1) e2

  prettyL l (LetDiamond _ _ v t e1 e2) =
    parens l $ "let " <> prettyL l v <> " :" <> prettyL l t <> " <- "
                       <> prettyL l e1 <> " in " <> prettyL l e2

  prettyL l (Val _ _ v) = prettyL l v
  prettyL l (Case _ _ e ps) = "\n    (case " <> prettyL l e <> " of\n      "
                      <> intercalate ";\n      " (map (\(p, e') -> prettyL l p
                      <> " -> " <> prettyL l e') ps) <> ")"

parensOn :: (?globals :: Globals) => Pretty a => (a -> Bool) -> a -> String
parensOn p t = prettyL (if p t then 0 else 1) t

instance Pretty Int where
  prettyL l = show

instance Pretty Span where
  prettyL _ (Span start end fileName) = "(" <> pretty start <> ":" <> pretty end <> ")"
