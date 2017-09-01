{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE PolyKinds              #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE UndecidableInstances   #-}

{-# OPTIONS_GHC -Wall      #-}

module Language.Fortran.TypeModel.Eval where

import           Control.Applicative                        (liftA2)
import           Control.Monad.Reader.Class                 (MonadReader (..))

import           Data.SBV                                   (SDouble, SFloat,
                                                             SReal, sRTZ)
import qualified Data.SBV                                   as SBV
import           Data.SBV.Dynamic                           (SArr, SVal)
import qualified Data.SBV.Dynamic                           as SBV
import           Data.SBV.Internals                         (SBV (..))

import           Data.Singletons
import           Data.Singletons.Prelude.List
import           Data.Singletons.TypeLits

import           Data.Vinyl                                 hiding (Field)
import           Data.Vinyl.Curry

import           Language.Fortran.TypeModel.Eval.Primitives
import           Language.Fortran.TypeModel.Match
import           Language.Fortran.TypeModel.Operator.Core
import           Language.Fortran.TypeModel.Singletons
import           Language.Fortran.TypeModel.Types

--------------------------------------------------------------------------------
--  Monad
--------------------------------------------------------------------------------

class (MonadReader r m, HasSymReprs r) => MonadEvalFortran r m | m -> r where
instance (MonadReader r m, HasSymReprs r) => MonadEvalFortran r m where

--------------------------------------------------------------------------------
--  Evaluation
--------------------------------------------------------------------------------

evalFortranOp
  :: (MonadEvalFortran r m)
  => Op (Length args) ok -> OpResult ok args result -> Rec SymRepr args -> m (SymRepr result)
evalFortranOp op opr = case opr of
  ORLit px x -> \_ -> primFromVal px <$> primLit px x

  ORNum1 _ _ p2 ->
    primUnop True p2 (numUnop op)
  ORNum2 nk1 nk2 p1 p2 p3 ->
    primBinop True p1 p2 p3 (numBinop (nkBothInts nk1 nk2) op)

  ORLogical1 _ p2 -> primUnop True p2 (logicalUnop op)
  ORLogical2 p1 p2 p3 -> primBinop True p1 p2 p3 (logicalBinop op)

  OREq cmp p1 p2 p3 -> primBinop False p1 p2 p3 (eqBinop cmp op)
  ORRel cmp p1 p2 p3 -> primBinop False p1 p2 p3 (relBinop cmp op)

  ORLookup (DArray (Index _) (ArrValue elPrim)) ->
    return . runcurry (\xs index ->
      let xsArr = toArr xs
          indexVal = primToVal index
      in primFromVal elPrim (SBV.readSArr xsArr indexVal))

  ORWriteArr _ -> return . runcurry writeArray

  ORDeref _ s -> return . runcurry (derefData s Proxy)
  ORWriteData _ s _ -> return . runcurry (writeDataAt s)

--------------------------------------------------------------------------------
--  General
--------------------------------------------------------------------------------

primToVal :: SymRepr (PrimS a) -> SVal
primToVal = \case
  SRPrim (DPrim _) v -> v

primFromVal :: Prim p k a -> SVal -> SymRepr (PrimS a)
primFromVal p v = SRPrim (DPrim p) v

toArr :: SymRepr (Array i v) -> SArr
toArr (SRArray _ x) = x

fromArr :: Index i -> ArrValue a -> SArr -> SymRepr (Array i a)
fromArr index av = SRArray (DArray index av)

primUnop
  :: (MonadEvalFortran r m)
  => Bool
  -> Prim p2 k2 b -- ^ The target type
  -> (SVal -> SVal)
  -> Rec SymRepr '[PrimS a] -> m (SymRepr (PrimS b))
primUnop shouldCoerce p2 f = runcurry $ fmap (primFromVal p2 . f) . maybeCoerce . primToVal
  where
    maybeCoerce
      | shouldCoerce = coerceSBVNum p2
      | otherwise = return

primBinop
  :: (MonadEvalFortran r m)
  => Bool
  -- ^ True to coerce arguments to result value. False to coerce arguments to
  -- ceiling of each.
  -> Prim p1 k1 a -> Prim p2 k2 b -> Prim p3 k3 c
  -> (SVal -> SVal -> SVal)
  -> Rec SymRepr '[PrimS a, PrimS b] -> m (SymRepr (PrimS c))
primBinop takesResultVal p1 p2 p3 (.*.) =
  fmap (primFromVal p3) .
  runcurry (\x y -> liftA2 (.*.) (coerceArg (primToVal x)) (coerceArg (primToVal y)))

  where
    coerceToCeil = case primCeil p1 p2 of
      Just (MakePrim pCeil) -> coerceSBVNum pCeil
      _                     -> return

    coerceArg
      | takesResultVal = coerceSBVNum p3
      | otherwise = coerceToCeil

--------------------------------------------------------------------------------
--  SBV Kinds
--------------------------------------------------------------------------------

coerceBy :: (SBV a -> SBV b) -> SVal -> SVal
coerceBy f x = unSBV (f (SBV x))

coerceNumKinds :: SBV.Kind -> SBV.Kind -> (SVal -> SVal)
coerceNumKinds SBV.KReal   SBV.KReal = id
coerceNumKinds SBV.KFloat  SBV.KReal = coerceBy (SBV.fromSFloat sRTZ :: SFloat -> SReal)
coerceNumKinds SBV.KDouble SBV.KReal = coerceBy (SBV.fromSDouble sRTZ :: SDouble -> SReal)
coerceNumKinds _        k2@SBV.KReal = SBV.svFromIntegral k2

coerceNumKinds SBV.KReal   SBV.KDouble = coerceBy (SBV.toSDouble sRTZ :: SReal -> SDouble)
coerceNumKinds SBV.KDouble SBV.KDouble = id
coerceNumKinds SBV.KFloat  SBV.KDouble = coerceBy (SBV.toSDouble sRTZ :: SFloat -> SDouble)
coerceNumKinds _        k2@SBV.KDouble = SBV.svFromIntegral k2

coerceNumKinds SBV.KReal   SBV.KFloat = coerceBy (SBV.toSFloat sRTZ :: SReal -> SFloat)
coerceNumKinds SBV.KDouble SBV.KFloat = coerceBy (SBV.toSFloat sRTZ :: SDouble -> SFloat)
coerceNumKinds SBV.KFloat  SBV.KFloat = id
coerceNumKinds _        k2@SBV.KFloat = SBV.svFromIntegral k2

coerceNumKinds _ k2 = SBV.svFromIntegral k2

coerceSBVNum :: (MonadEvalFortran r m) => Prim p k a -> SVal -> m SVal
coerceSBVNum p v = do
  k2 <- primSBVKind p
  let k1 = SBV.kindOf v
  return $ coerceNumKinds k1 k2 v

--------------------------------------------------------------------------------
--  Numeric
--------------------------------------------------------------------------------

-- TODO: Worry about what happens when LHS and RHS have different types

nkBothInts :: NumericBasicType k1 -> NumericBasicType k2 -> Bool
nkBothInts NBTInt NBTInt = True
nkBothInts _ _           = False

numUnop :: Op 1 'OKNum -> SVal -> SVal
numUnop = \case
  OpNeg -> SBV.svUNeg
  OpPos -> id

numBinop :: Bool -> Op 2 'OKNum -> SVal -> SVal -> SVal
numBinop isInt = \case
  OpAdd -> SBV.svPlus
  OpSub -> SBV.svMinus
  OpMul -> SBV.svTimes
  OpDiv -> if isInt then SBV.svQuot else SBV.svDivide

--------------------------------------------------------------------------------
--  Logical
--------------------------------------------------------------------------------

-- TODO: Always return single bits, special-case when inputs are not single bits.

logicalUnop :: Op 1 'OKLogical -> SVal -> SVal
logicalUnop = \case
  OpNot -> SBV.svNot

logicalBinop :: Op 2 'OKLogical -> SVal -> SVal -> SVal
logicalBinop = \case
  OpAnd -> SBV.svAnd
  OpOr -> SBV.svOr
  OpEquiv -> svEquiv
  OpNotEquiv -> svNotEquiv
  where
    svEquiv x y = (x `SBV.svAnd` y) `SBV.svOr` (SBV.svNot x `SBV.svAnd` SBV.svNot y)
    svNotEquiv x y = SBV.svNot (x `svEquiv` y)

--------------------------------------------------------------------------------
--  Equality
--------------------------------------------------------------------------------

-- TODO: Worry about what happens when LHS and RHS have different types

eqBinop :: ComparableBasicTypes k1 k2 -> Op 2 'OKEq -> SVal -> SVal -> SVal
eqBinop _ = \case
  OpEq -> SBV.svEqual
  OpNE -> SBV.svNotEqual

--------------------------------------------------------------------------------
--  Relational
--------------------------------------------------------------------------------

-- TODO: Worry about what happens when LHS and RHS have different types

relBinop :: ComparableBasicTypes k1 k2 -> Op 2 'OKRel -> SVal -> SVal -> SVal
relBinop _ = \case
  OpLT -> SBV.svLessThan
  OpLE -> SBV.svLessEq
  OpGT -> SBV.svGreaterThan
  OpGE -> SBV.svGreaterEq

--------------------------------------------------------------------------------
--  Deref
--------------------------------------------------------------------------------

derefData
  :: RElem '(fname, a) fields i
  => SSymbol fname -> proxy a
  -> SymRepr (Record rname fields)
  -> SymRepr a
derefData nameSymbol valProxy (SRData _ dataRec) =
  case rget (pairProxy nameSymbol valProxy) dataRec of
    Field _ x -> x
  where
    pairProxy :: p1 a -> p2 b -> Proxy '(a, b)
    pairProxy _ _ = Proxy

--------------------------------------------------------------------------------
--  Write array
--------------------------------------------------------------------------------

writeArray :: SymRepr (Array i v) -> SymRepr i -> SymRepr v -> SymRepr (Array i v)
writeArray arrRep ixRep valRep =
  case arrRep of
    SRArray d@(DArray (Index _) (ArrValue _)) arr ->
      case (ixRep, valRep) of
        (SRPrim _ ixVal, SRPrim _ valVal) ->
          SRArray d (SBV.writeSArr arr ixVal valVal)

--------------------------------------------------------------------------------
--  Write Data
--------------------------------------------------------------------------------

writeDataAt
  :: RElem '(fname, a) fields i
  => SSymbol fname
  -> SymRepr (Record rname fields)
  -> SymRepr a
  -> SymRepr (Record rname fields)
writeDataAt fieldSymbol (SRData d dataRec) valRep =
  SRData d $ rput (Field fieldSymbol valRep) dataRec

--------------------------------------------------------------------------------
--  Equality of operators
--------------------------------------------------------------------------------

-- eqOpRArgs
--   :: (forall x y. (x -> y -> Bool) -> f x -> g y -> Bool)
--   -> OpResult ok1 args1 r1
--   -> OpResult ok2 args2 r2
--   -> Rec f args1
--   -> Rec g args2
--   -> Bool
-- eqOpRArgs le opr1 opr2 =
--   case (opr1, opr2) of
--     (ORLit _ _, ORLit _ _) -> \_ _ -> True
--     (ORNum1 _ px _, ORNum1 _ py _) -> runcurry $ runcurry . le (eqPrimS px py)
--     (ORNum2 _ _ px1 px2 _, ORNum2 _ _ py1 py2 _) ->
--       runcurry $ \x1 x2 -> runcurry $ \y1 y2 ->
--       le (eqPrimS px1 py1) x1 y1 && le (eqPrimS px2 py2) x2 y2
--     (ORLogical1 px _, ORLogical1 py _) -> runcurry $ runcurry . le (eqPrimS px py)
--     (ORLogical2 px1 px2 _, ORLogical2 py1 py2 _) ->
--       runcurry $ \x1 x2 -> runcurry $ \y1 y2 ->
--       le (eqPrimS px1 py1) x1 y1 && le (eqPrimS px2 py2) x2 y2
--     (OREq _ px1 px2 _, OREq _ py1 py2 _) ->
--       runcurry $ \x1 x2 -> runcurry $ \y1 y2 ->
--       le (eqPrimS px1 py1) x1 y1 && le (eqPrimS px2 py2) x2 y2
--     (ORRel _ px1 px2 _, ORRel _ py1 py2 _) ->
--       runcurry $ \x1 x2 -> runcurry $ \y1 y2 ->
--       le (eqPrimS px1 py1) x1 y1 && le (eqPrimS px2 py2) x2 y2
--     (ORLookup (DArray (Index pi1) _), ORLookup (DArray (Index pi2) _)) ->
--       runcurry $ \arr1 i1 -> runcurry $ \arr2 i2 ->
--       le _ arr1 arr2 && le (eqPrimS pi1 pi2) i1 i2
--       -- le ()

-- liftEqRec
--   :: (forall a b. f a -> g b -> Bool)
--   -> Rec f xs -> Rec g ys
--   -> Bool
-- liftEqRec f r1 r2 = case (r1, r2) of
--   (RNil, RNil) -> True
--   (h1 :& t1, h2 :& t2) -> f h1 h2 && liftEqRec f t1 t2
--   _ -> False
