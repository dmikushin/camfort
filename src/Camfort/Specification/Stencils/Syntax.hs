{-
   Copyright 2016, Dominic Orchard, Andrew Rice, Mistral Contrastin, Matthew Danish

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}

{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}

module Camfort.Specification.Stencils.Syntax where

import Camfort.Helpers
import Camfort.Specification.Stencils.Model ( Multiplicity(..)
                                            , peel
                                            , Approximation(..)
                                            , lowerBound, upperBound
                                            , fromExact
                                            )

import Prelude hiding (sum)

import Data.Data
import Data.Generics.Uniplate.Data
import Data.List hiding (sum)
import Data.Function
import Data.Maybe
import Debug.Trace
import Control.Applicative

type Variable = String

{-  Contains the syntax representation for stencil specifications -}

{- *** 0. Representations -}

-- 'absoluteRep' is an integer to use to represent absolute indexing expressions
-- (which may be constants, non-affine indexing expressions, or expressions
--  involving non-induction variables). This is set to maxBoound :: Int usually,
-- but can be made smaller for debugging purposes,
-- e.g., 100, but it needs to be high enough to clash with reasonable
-- relative indices.
absoluteRep = maxBound :: Int

{- *** 1 . Specification syntax -}

-- List of region sums associated to region variables
type RegionEnv = [(String, RegionSum)]

-- List of specifications associated to variables
-- This is not a map so there might be multiple entries for each variable
-- use `lookupAggregate` to access it
type SpecDecls = [([String], Specification)]

pprintSpecDecls :: SpecDecls -> String
pprintSpecDecls =
 concatMap (\(names, spec) ->
            show spec ++ " :: " ++ intercalate "," names ++ "\n")

lookupAggregate :: Eq a => [([a], b)] -> a -> [b]
lookupAggregate [] _ = []
lookupAggregate ((names, spec) : ss) name =
  if name `elem` names
  then spec : lookupAggregate ss name
  else lookupAggregate ss name

-- Top-level of specifications: may be either spatial or temporal
data Specification =
  Specification (Multiplicity (Approximation Spatial))
    deriving (Eq, Data, Typeable)

isEmpty :: Specification -> Bool
isEmpty (Specification mult) = isUnit . peel $ mult

-- **********************
-- Spatial specifications:
-- is a regionSum
--
-- Regions are in disjunctive normal form (with respect to
--  products on dimensions and sums):
--    i.e., (A * B) U (C * D)...
data Spatial = Spatial RegionSum
  deriving (Eq, Data, Typeable)

-- Helpers for dealing with linearity information

-- A boolean is used to represent multiplicity in the backend
-- with False = multiplicity=1 and True = multiplicity > 1
fromBool :: Bool -> Linearity
fromBool True = NonLinear
fromBool False = Linear

hasDuplicates :: Eq a => [a] -> ([a], Bool)
hasDuplicates xs = (nub xs, nub xs /= xs)

setLinearity :: Linearity -> Specification -> Specification
setLinearity l (Specification mult)
  | l == Linear = Specification $ Once $ peel mult
  | l == NonLinear = Specification $ Mult $ peel mult

data Linearity = Linear | NonLinear deriving (Eq, Data, Typeable)

type Dimension  = Int -- spatial dimensions are 1 indexed
type Depth      = Int
type IsRefl     = Bool

-- Individual regions
data Region where
    Forward  :: Depth -> Dimension -> IsRefl -> Region
    Backward :: Depth -> Dimension -> IsRefl -> Region
    Centered :: Depth -> Dimension -> IsRefl -> Region
  deriving (Eq, Data, Typeable)

getDimension :: Region -> Dimension
getDimension (Forward _ dim _) = dim
getDimension (Backward _ dim _) = dim
getDimension (Centered _ dim _) = dim

-- An (arbitrary) ordering on regions for the sake of normalisation
instance Ord Region where
  (Forward dep dim _) <= (Forward dep' dim' _)
    | dep == dep' = dim <= dim'
    | otherwise   = dep <= dep'

  (Backward dep dim _) <= (Backward dep' dim' _)
    | dep == dep' = dim <= dim'
    | otherwise   = dep <= dep'

  (Centered dep dim _) <= (Centered dep' dim' _)
    | dep == dep' = dim <= dim'
    | otherwise   = dep <= dep'

  -- Order in the way defined above: Forward <: Backward <: Centered
  Forward{}  <= _          = True
  Backward{} <= Centered{} = True
  _          <= _          = False

-- Product of specifications
newtype RegionProd = Product {unProd :: [Region]}
  deriving (Eq, Data, Typeable)

-- Sum of product specifications
newtype RegionSum = Sum {unSum :: [RegionProd]}
  deriving (Eq, Data, Typeable)

instance Ord RegionProd where
   (Product xs) <= (Product xs') = xs <= xs'


-- Operations on specifications

regionPlus :: Region -> Region -> Maybe Region
regionPlus (Forward dep dim reflx) (Backward dep' dim' reflx')
    | dep == dep' && dim == dim' = Just $ Centered dep dim (reflx || reflx')
regionPlus (Backward dep dim reflx) (Forward dep' dim' reflx')
    | dep == dep' && dim == dim' = Just $ Centered dep dim (reflx || reflx')
regionPlus x y | x == y          = Just x
regionPlus x y                   = Nothing

instance PartialMonoid RegionProd where
   emptyM = Product []

   appendM (Product [])   s  = Just s
   appendM s (Product [])    = Just s
   appendM (Product [s]) (Product [s']) =
       regionPlus s s' >>= (\sCombined -> return $ Product [sCombined])
   appendM (Product ss) (Product ss')
       | ss == ss' = Just $ Product ss
       | otherwise =
         case absorbReflexive ss ss' of
           Just (ss0, ss1) ->
               case distAndOverlaps ss0 ss1 of
                 Just ss'' -> return $ Product $ sort ss''
                 Nothing   -> return $ Product $ sort (ss0 ++ ss1)
           Nothing -> case distAndOverlaps ss ss' of
                        Just ss'' -> return $ Product $ sort ss''
                        Nothing   -> Nothing

--Based on equations:
-- Forward n d + Reflexive d = Forward n d
-- Backward n d + Reflexive d = Backward n d
-- Centered n d + Reflexive d = Centered n d
-- (and so on for n-ary cases and Backward and Centered).

absorbReflexive :: [Region] -> [Region] -> Maybe ([Region], [Region])
absorbReflexive a b =
      absorbReflexive' (sortBy cmpDims a) (sortBy cmpDims b)
  <|> absorbReflexive' (sortBy cmpDims b) (sortBy cmpDims a)
  where cmpDims = compare `on` getDimension

absorbReflexive' [] [] = Just ([], [])
absorbReflexive' (Forward d dim reflx : rs) [Centered 0 dim' _]
  | dim == dim' = Just (Forward d dim True:rs, [])

absorbReflexive' (Backward d dim reflx : rs) [Centered 0 dim' _]
  | dim == dim' = Just (Backward d dim True:rs, [])

absorbReflexive' (Centered d dim reflx : rs) [Centered 0 dim' _]
  | dim == dim' && d /= 0 = Just (Centered d dim True:rs, [])

absorbReflexive' _ _ = Nothing

-- Implements a combination of (+DIST), (+COMM), and (OVERLAPS)
distAndOverlaps :: [Region] -> [Region] -> Maybe [Region]
distAndOverlaps x y =
    if length x <= 1 || length y <= 1
    then Nothing
    else -- (+COMM)
         distAndOverlaps' x y <|> distAndOverlaps' y x

distAndOverlaps' [] xs = Just xs
distAndOverlaps' xs [] = Just xs

-- F+F
distAndOverlaps' (Forward d dim refl : rs) (Forward d' dim' refl' : rs')
  | rs == rs' && dim == dim'
      = Just (Forward (max d d') dim (refl || refl') : rs)

-- B+B
distAndOverlaps' (Backward d dim refl : rs) (Backward d' dim' refl' : rs')
  | rs == rs' && dim == dim'
      = Just (Backward (max d d') dim (refl || refl') : rs)

-- C+C
distAndOverlaps' (Centered d dim refl : rs) (Centered d' dim' refl' : rs')
  | rs == rs' && dim == dim' && d /= 0 && d' /= 0
      = Just (Centered (max d d') dim (refl || refl') : rs)

-- C+F
distAndOverlaps' (Forward d dim refl : rs) (Centered d' dim' refl' : rs')
  | rs == rs' && dim == dim' && d <= d' && d' /= 0
      = Just (Centered d' dim (refl || refl') : rs)

-- C+B
distAndOverlaps' (Backward d dim refl : rs) (Centered d' dim' refl' : rs')
  | rs == rs' && dim == dim' && d <= d' && d' /= 0
      = Just (Centered d' dim (refl || refl') : rs)

-- F+B
distAndOverlaps' (Forward d dim reflx : rs) (Backward d' dim' reflx' : rs')
    | rs == rs' && d == d' && dim == dim'
      = Just (Centered d dim (reflx || reflx') : rs)

-- C+R
distAndOverlaps' (Centered d dim reflx : rs) (Centered 0 dim' True : rs')
    | rs == rs' && dim == dim' && d /= 0
      = Just (Centered d dim True : rs)

-- F+R
distAndOverlaps' (Forward d dim reflx : rs) (Centered 0 dim' True : rs')
    | rs == rs' && dim == dim'
      = Just (Forward d dim True : rs)

-- B+R
distAndOverlaps' (Backward d dim reflx : rs) (Centered 0 dim' True : rs')
    | rs == rs' && dim == dim'
      = Just (Backward d dim True : rs)

-- IRREFL B+!B
distAndOverlaps' p1@(Backward d1 dim1 refl1 : Backward d2 dim2 refl2 : rs)
                 p2@(Backward d1' dim1' refl1' : Backward d2' dim2' refl2' : rs')
    | rs == rs' && dim1 == dim1' && dim2 == dim2'
      && d1 == d1' && d2 == d2' && refl1 == not refl1' && refl2 == not refl2'
      = Just $ [Backward d1 dim1 True, Backward d2 dim2 True] ++ rs

    | rs == rs' && dim1 == dim2' && dim2 == dim1'
      && d1 == d2' && d2 == d1' && refl1 == not refl2' && refl2 == not refl1'
      = Just $ [Backward d1 dim1 True, Backward d2 dim2 True] ++ rs

-- IRREFL C+!C
distAndOverlaps' p1@(Centered d1 dim1 refl1 : Centered d2 dim2 refl2 : rs)
                 p2@(Centered d1' dim1' refl1' : Centered d2' dim2' refl2' : rs')
    | rs == rs' && dim1 == dim1' && dim2 == dim2' && (d1 * d2 * d1' * d2' /= 0)
      && d1 == d1' && d2 == d2' && refl1 == not refl1' && refl2 == not refl2'
      = Just $ [Centered d1 dim1 True, Centered d2 dim2 True] ++ rs

    | rs == rs' && dim1 == dim2' && dim2 == dim1'
      && d1 == d2' && d2 == d1' && refl1 == not refl2' && refl2 == not refl1'
      = Just $ [Centered d1 dim1 True, Centered d2 dim2 True] ++ rs

-- IRREFL F+!F
distAndOverlaps' p1@(Forward d1 dim1 refl1 : Forward d2 dim2 refl2 : rs)
                 p2@(Forward d1' dim1' refl1' : Forward d2' dim2' refl2' : rs')
    | rs == rs' && dim1 == dim1' && dim2 == dim2' && (d1 * d2 * d1' * d2' /= 0)
      && d1 == d1' && d2 == d2' && refl1 == not refl1' && refl2 == not refl2'
      = Just $ [Forward d1 dim1 True, Forward d2 dim2 True] ++ rs

    | rs == rs' && dim1 == dim2' && dim2 == dim1' && (d1 * d2 * d1' * d2' /= 0)
      && d1 == d2' && d2 == d1' && refl1 == not refl2' && refl2 == not refl1'
      = Just $ [Forward d1 dim1 True, Forward d2 dim2 True] ++ rs

-- push any remaining idempotence through dist
-- distAndOverlaps(r*s + r*s') = r*(distAndOverlaps (s + s'))
distAndOverlaps' (r:rs) (r':rs')
    | r == r'   = do rs'' <- distAndOverlaps rs rs'
                     return $ r : rs''

distAndOverlaps' _ _ = Nothing


-- Operations on region specifications form a semiring
--  where `sum` is the additive, and `prod` is the multiplicative
--  [without the annihilation property for `zero` with multiplication]
class RegionRig t where
  sum  :: t -> t -> t
  prod :: t -> t -> t
  one  :: t
  zero :: t
  isUnit :: t -> Bool

-- Lifting to the `Maybe` constructor
instance RegionRig a => RegionRig (Maybe a) where
  sum (Just x) (Just y) = Just $ sum x y
  sum x Nothing = x
  sum Nothing x = x

  prod (Just x) (Just y) = Just $ prod x y
  prod x Nothing = x
  prod Nothing x = x

  one  = Just one
  zero = Just zero

  isUnit Nothing = True
  isUnit (Just x) = isUnit x

instance RegionRig Spatial where
  sum (Spatial s) (Spatial s') = Spatial (sum s s')

  prod (Spatial s) (Spatial s') = Spatial (prod s s')

  one = Spatial one
  zero = Spatial zero

  isUnit (Spatial ss) = isUnit ss

instance RegionRig (Approximation Spatial) where
  sum (Exact s) (Exact s')      = Exact (sum s s')
  sum (Exact s) (Bound l u)     = Bound (sum (Just s) l) (sum (Just s) u)
  sum (Bound l u) (Bound l' u') = Bound (sum l l') (sum u u')
  sum s s'                      = sum s' s

  prod (Exact s) (Exact s')      = Exact (prod s s')
  prod (Exact s) (Bound l u)     = Bound (prod (Just s) l) (prod (Just s) u)
  prod (Bound l u) (Bound l' u') = Bound (prod l l') (prod u u') -- (prod l u') (prod l' u))
  prod s s'                      = prod s' s

  one  = Exact one
  zero = Exact zero

  isUnit (Exact s) = isUnit s
  isUnit (Bound x y) = isUnit x && isUnit y

instance RegionRig RegionSum where
  prod (Sum ss) (Sum ss') =
   Sum $ nub $ -- Take the cross product of list of summed specifications
     do (Product spec) <- ss
        (Product spec') <- ss'
        return $ Product $ nub $ sort $ spec ++ spec'
  sum (Sum ss) (Sum ss') = Sum $ normalise $ ss ++ ss'
  zero = Sum []
  one = Sum [Product []]
  isUnit s@(Sum ss) = s == zero || s == one || all (== Product []) ss

-- Show a list with ',' separator
showL :: Show a => [a] -> String
showL = intercalate "," . map show

-- Show lists with '*' or '+' separator (used to represent product of regions)
showProdSpecs, showSumSpecs :: Show a => [a] -> String
showProdSpecs = intercalate "*" . map show
showSumSpecs  = intercalate "+" . map show

-- Pretty print top-level specifications
instance Show Specification where
  show (Specification sp) = "stencil " ++ show sp

instance {-# OVERLAPS #-} Show (Multiplicity (Approximation Spatial)) where
  show mult
    | Mult appr <- mult = apprStr empty empty appr
    | Once appr <- mult = apprStr "readOnce" ", " appr
    where
      apprStr linearity sep appr =
        case appr of
          Exact s -> linearity ++ optionalSeparator sep (show s)
          Bound Nothing Nothing -> "empty"
          Bound Nothing (Just s) -> "atMost, " ++ linearity ++ optionalSeparator sep (show s)
          Bound (Just s) Nothing -> "atLeast, " ++ linearity ++ optionalSeparator sep (show s)
          Bound (Just sL) (Just sU) ->
            "atLeast, " ++ linearity ++ optionalSeparator sep (show sL) ++
            "; atMost, " ++ linearity ++ optionalSeparator sep (show sU)
      optionalSeparator sep "" = ""
      optionalSeparator sep s  = sep ++ s

instance {-# OVERLAPS #-} Show (Approximation Spatial) where
  show (Exact s) = show s
  show (Bound Nothing Nothing) = "empty"
  show (Bound Nothing (Just s)) = "atMost, " ++ show s
  show (Bound (Just s) Nothing) = "atLeast, " ++ show s
  show (Bound (Just sL) (Just sU)) =
      "atLeast, " ++ show sL ++ "; atMost, " ++ show sU

-- Pretty print spatial specs
instance Show Spatial where
  show (Spatial region) =
    -- Map "empty" spec to Nothing here
    case show region of
      "empty" -> ""
      xs      -> xs

-- Pretty print region sums
instance Show RegionSum where
    -- Tweedle-dum
    show (Sum []) = "empty"
    -- Tweedle-dee
    show (Sum [Product []]) = "empty"

    show (Sum specs) =
      intercalate " + " ppspecs
      where ppspecs = filter (/= "") $ map show specs

instance Show RegionProd where
    show (Product []) = ""
    show (Product ss)  =
       intercalate "*" . map (\s -> "(" ++ show s ++ ")") $ ss

instance Show Region where
   show (Forward dep dim reflx)   = showRegion "forward" dep dim reflx
   show (Backward dep dim reflx)  = showRegion "backward" dep dim reflx
   show (Centered dep dim reflx)
     | dep == 0 = "pointed(dim=" ++ show dim ++ ")"
     | otherwise = showRegion "centered" dep dim reflx

-- Helper for showing regions
showRegion typ depS dimS reflx = typ ++ "(depth=" ++ show depS
                               ++ ", dim=" ++ show dimS
                               ++ (if reflx then "" else ", nonpointed")
                               ++ ")"

-- Helper for reassociating an association list, grouping the keys together that
-- have matching values
groupKeyBy :: Eq b => [(a, b)] -> [([a], b)]
groupKeyBy = groupKeyBy' . map (\ (k, v) -> ([k], v))
  where
    groupKeyBy' []        = []
    groupKeyBy' [(ks, v)] = [(ks, v)]
    groupKeyBy' ((ks1, v1):((ks2, v2):xs))
      | v1 == v2          = groupKeyBy' ((ks1 ++ ks2, v1) : xs)
      | otherwise         = (ks1, v1) : groupKeyBy' ((ks2, v2) : xs)
