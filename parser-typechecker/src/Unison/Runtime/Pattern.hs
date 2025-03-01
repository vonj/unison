{-# language BangPatterns #-}
{-# language ViewPatterns #-}
{-# language PatternGuards #-}
{-# language TupleSections #-}
{-# language PatternSynonyms #-}
{-# language OverloadedStrings #-}

module Unison.Runtime.Pattern
  ( DataSpec
  , splitPatterns
  , builtinDataSpec
  ) where

import Control.Lens ((<&>))
import Control.Monad.State (State, state, evalState, runState, modify)

import Data.List (transpose)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Word (Word64)

import Data.Set (Set, member)
import qualified Data.Set as Set

import Unison.ABT
  (absChain', visitPure, pattern AbsN', changeVars)
import Unison.Builtin.Decls (builtinDataDecls, builtinEffectDecls)
import Unison.DataDeclaration (declFields)
import Unison.Pattern
import qualified Unison.Pattern as P
import Unison.Reference (Reference(..))
import Unison.Symbol (Symbol)
import Unison.Term hiding (Term)
import qualified Unison.Term as Tm
import Unison.Var (Var, typed, freshIn, freshenId, Type(Pattern))

import qualified Unison.Type as Rf

import Data.Map.Strict
  (Map, toList, fromListWith, insertWith)
import qualified Data.Map.Strict as Map

type Term v = Tm.Term v ()

-- Represents the number of fields of constructors of a data type/
-- ability in order of constructors
type Cons = [Int]
type NCons = [(Int,Int)]

-- Maps references to the constructor information for abilities (left)
-- and data types (right)
type DataSpec = Map Reference (Either Cons Cons)

data PType = PData Reference | PReq (Set Reference) | Unknown

instance Semigroup PType where
  Unknown <> r = r
  l <> Unknown = l
  t@(PData l) <> PData r
    | l == r = t
  PReq l <> PReq r = PReq (l <> r)
  _ <> _ = error "inconsistent pattern matching types"

instance Monoid PType where
  mempty = Unknown
  mappend = (<>)

type Ctx v = Map v PType

-- Representation of a row in a pattern compilation matrix.
-- There is a list of patterns annotated with the variables they
-- are matching against, an optional guard, and the body of the
-- 'match' clause associated with this row.
data PatternRow v
  = PR
  { matches :: [Pattern v]
  , guard :: Maybe (Term v)
  , body :: Term v
  } deriving (Show)

-- This is the data and ability 'constructor' information for all
-- the things defined in Haskell source code.
builtinDataSpec :: DataSpec
builtinDataSpec = Map.fromList decls
 where
 decls = [ (DerivedId x, declFields $ Right y)
         | (_,x,y) <- builtinDataDecls @Symbol ]
      ++ [ (DerivedId x, declFields $ Left y)
         | (_,x,y) <- builtinEffectDecls @Symbol ]

-- A pattern compilation matrix is just a list of rows. There is
-- no need for the rows to have uniform length; the variable
-- annotations on the patterns in the rows keep track of what
-- should be matched against when decomposing a matrix.
data PatternMatrix v
  = PM { _rows :: [PatternRow v] }
  deriving Show

-- Heuristics guide the pattern compilation. They inspect the
-- pattern matrix and (may) choose a variable to split on next.
-- The full strategy will consist of multiple heuristics composed
-- in series.
type Heuristic v = PatternMatrix v -> Maybe v

choose :: [Heuristic v] -> PatternMatrix v -> v
choose [] (PM (PR (p:_) _ _ : _)) = loc p
choose [] _ = error "pattern matching: failed to choose a splitting"
choose (h:hs) m
  | Just i <- h m = i
  | otherwise = choose hs m

refutable :: P.Pattern a -> Bool
refutable (P.Unbound _) = False
refutable (P.Var _) = False
refutable _ = True

rowIrrefutable :: PatternRow v -> Bool
rowIrrefutable (PR ps _ _) = null ps

firstRow :: ([P.Pattern v] -> Maybe v) -> Heuristic v
firstRow f (PM (r:_)) = f $ matches r
firstRow _ _ = Nothing

heuristics :: [Heuristic v]
heuristics = [firstRow $ fmap loc . listToMaybe]

extractVar :: Var v => P.Pattern v -> Maybe v
extractVar p
  | P.Unbound{} <- p = Nothing
  | otherwise = Just (loc p)

extractVars :: Var v => [P.Pattern v] -> [v]
extractVars = catMaybes . fmap extractVar

-- Splits a data type pattern, yielding its subpatterns. The provided
-- integers are the tag and number of fields for the constructor being
-- matched against. A constructor pattern thus only yields results if
-- it matches the tag (and number of subpatterns as a consistency
-- check), while variables can also match and know how many subpatterns
-- to yield.
--
-- The outer list indicates success of the match. It could be Maybe,
-- but elsewhere these results are added to a list, so it is more
-- convenient to yield a list here.
decomposePattern
  :: Var v
  => Reference -> Int -> Int -> P.Pattern v
  -> [[P.Pattern v]]
decomposePattern rf0 t _       (P.Boolean _ b)
  | rf0 == Rf.booleanRef
  , t == if b then 1 else 0
  = [[]]
decomposePattern rf0 t nfields p@(P.Constructor _ rf u ps)
  | t == u
  , rf0 == rf
  = if length ps == nfields
    then [ps]
    else error err
  where
  err = "decomposePattern: wrong number of constructor fields: "
     ++ show (nfields, p)
decomposePattern rf0 t nfields p@(P.EffectBind _ rf u ps pk)
  | t == u
  , rf0 == rf
  = if length ps == nfields
    then [ps ++ [pk]]
    else error err
  where
  err = "decomposePattern: wrong number of ability fields: "
     ++ show (nfields, p)
decomposePattern _ t _ (P.EffectPure _ p)
  | t == -1 = [[p]]
decomposePattern _ _ nfields (P.Var _)
  = [replicate nfields (P.Unbound (typed Pattern))]
decomposePattern _ _ nfields (P.Unbound _)
  = [replicate nfields (P.Unbound (typed Pattern))]
decomposePattern _ _ _ (P.SequenceLiteral _ _)
  = error "decomposePattern: sequence literal"
decomposePattern _ _ _ _ = []

matchBuiltin :: P.Pattern a -> Maybe (P.Pattern ())
matchBuiltin (P.Var _) = Just $ P.Unbound ()
matchBuiltin (P.Unbound _) = Just $ P.Unbound ()
matchBuiltin (P.Nat _ n) = Just $ P.Nat () n
matchBuiltin (P.Int _ n) = Just $ P.Int () n
matchBuiltin (P.Text _ t) = Just $ P.Text () t
matchBuiltin (P.Char _ c) = Just $ P.Char () c
matchBuiltin (P.Float _ d) = Just $ P.Float () d
matchBuiltin _ = Nothing

-- Represents the various cases that that may occur when performing
-- a sequence match. These fall into two groups:
--
--   E, C, S: empty, cons, snoc
--   L, R, DL, DR: split left/right, insufficient elements
--
-- These groups correspond to different sorts of matches we can compile
-- to. We can view the left/right end of a sequence, or attempt to
-- split a sequence at a specified offset from the left/right side.
data SeqMatch = E | C | S | L Int | R Int | DL Int | DR Int
  deriving (Eq,Ord,Show)

seqPSize :: P.Pattern v -> Maybe Int
seqPSize (P.SequenceLiteral _ l) = Just $ length l
seqPSize (P.SequenceOp _ _ Cons r) = (1+) <$> seqPSize r
seqPSize (P.SequenceOp _ l Snoc _) = (1+) <$> seqPSize l
seqPSize (P.SequenceOp _ l Concat r) = (+) <$> seqPSize l <*> seqPSize r
seqPSize _ = Nothing

-- Decides a sequence matching operation to perform based on a column
-- of patterns that match against it. Literals do not really force a
-- bias, so the decision of which side to view is postponed to
-- subsequent patterns if we encounter a literal first. A literal with
-- priority does block a splitting pattern, though.
decideSeqPat :: [P.Pattern v] -> [SeqMatch]
decideSeqPat = go False
  where
  go _ [] = [E,C]
  go _ (P.SequenceLiteral{} : ps) = go True ps
  go _ (P.SequenceOp _ _ Snoc _ : _) = [E,S]
  go _ (P.SequenceOp _ _ Cons _ : _) = [E,C]

  go guard (P.SequenceOp _ l Concat r : _)
    | guard = [E,C] -- prefer prior literals
    | Just n <- seqPSize l = [L n, DL n]
    | Just n <- seqPSize r = [R n, DR n]
  go b (P.Unbound _ : ps) = go b ps
  go b (P.Var _ : ps) = go b ps
  go _ (p:_)
    = error $ "Cannot process sequence pattern: " ++ show p

-- Represents the possible correspondences between a sequence pattern
-- and a sequence matching compilation target. Unlike data matching,
-- where a pattern either matches or is disjoint from a tag, sequence
-- patterns can overlap in non-trivial ways where it would be difficult
-- to avoid re-testing the original list.
data SeqCover v
  = Cover [P.Pattern v]
  | Disjoint
  | Overlap

-- Determines how a pattern corresponds to a sequence matching
-- compilation target.
decomposeSeqP :: Var v => Set v -> SeqMatch -> P.Pattern v -> SeqCover v
decomposeSeqP _ E (P.SequenceLiteral _ []) = Cover []
decomposeSeqP _ E _ = Disjoint

decomposeSeqP _ C (P.SequenceOp _ l Cons r) = Cover [l,r]
decomposeSeqP _ C (P.SequenceOp _ _ Concat _) = Overlap
decomposeSeqP _ C (P.SequenceLiteral _ []) = Disjoint
decomposeSeqP avoid C (P.SequenceLiteral _ (p:ps))
  = Cover [p, P.SequenceLiteral u ps]
  where u = freshIn avoid $ typed Pattern

decomposeSeqP _ S (P.SequenceOp _ l Snoc r) = Cover [l,r]
decomposeSeqP _ S (P.SequenceOp _ _ Concat _) = Overlap
decomposeSeqP _ S (P.SequenceLiteral _ []) = Disjoint
decomposeSeqP avoid S (P.SequenceLiteral _ ps)
  = Cover [P.SequenceLiteral u (init ps), last ps]
  where u = freshIn avoid $ typed Pattern

decomposeSeqP _ (L n) (P.SequenceOp _ l Concat r)
  | Just m <- seqPSize l
  , n == m
  = Cover [l,r]
  | otherwise = Overlap
decomposeSeqP avoid (L n) (P.SequenceLiteral _ ps)
  | length ps >= n
  , (pl, pr) <- splitAt n ps
  = Cover $ P.SequenceLiteral u <$> [pl,pr]
  | otherwise = Disjoint
  where u = freshIn avoid $ typed Pattern

decomposeSeqP _ (R n) (P.SequenceOp _ l Concat r)
  | Just m <- seqPSize r
  , n == m
  = Cover [l,r]
decomposeSeqP avoid (R n) (P.SequenceLiteral _ ps)
  | length ps >= n
  , (pl, pr) <- splitAt (length ps - n) ps
  = Cover $ P.SequenceLiteral u <$> [pl,pr]
  | otherwise = Disjoint
  where u = freshIn avoid $ typed Pattern

decomposeSeqP _ (DL n) (P.SequenceOp _ l Concat _)
  | Just m <- seqPSize l , n == m = Disjoint
decomposeSeqP _ (DL n) (P.SequenceLiteral _ ps)
  | length ps >= n = Disjoint

decomposeSeqP _ (DR n) (P.SequenceOp _ _ Concat r)
  | Just m <- seqPSize r , n == m = Disjoint
decomposeSeqP _ (DR n) (P.SequenceLiteral _ ps)
  | length ps >= n = Disjoint

decomposeSeqP _ _ _ = Overlap

-- Splits a pattern row with respect to matching a variable against a
-- data type constructor. If the row would match the specified
-- constructor, the subpatterns and resulting row are yielded. A list
-- is used as the result value to indicate success or failure to match,
-- because these results are accumulated into a larger list elsewhere.
splitRow
  :: Var v
  => v
  -> Reference
  -> Int
  -> Int
  -> PatternRow v
  -> [([P.Pattern v], PatternRow v)]
splitRow v rf t nfields (PR (break ((==v).loc) -> (pl, sp : pr)) g b)
  = decomposePattern rf t nfields sp
      <&> \subs -> (subs, PR (pl ++ filter refutable subs ++ pr) g b)
splitRow _ _ _ _ row = [([],row)]

-- Splits a row with respect to a variable, expecting that the
-- variable will be matched against a builtin pattern (non-data type,
-- non-request, non-sequence). In addition to returning the
-- subpatterns and new row, returns a version of the pattern that was
-- matched against the variable that may be collected to determine the
-- cases the built-in value is matched against.
splitRowBuiltin
  :: Var v
  => v
  -> PatternRow v
  -> [(P.Pattern (), [([P.Pattern v], PatternRow v)])]
splitRowBuiltin v (PR (break ((==v).loc) -> (pl, sp : pr)) g b)
  | Just p <- matchBuiltin sp = [(p, [([], PR (pl ++ pr) g b)])]
  | otherwise = []
splitRowBuiltin _ r = [(P.Unbound (), [([], r)])]

-- Splits a row with respect to a variable, expecting that the
-- variable will be matched against a sequence matching operation.
-- Yields the subpatterns and a new row to be used in subsequent
-- compilation. The outer list result is used to indicate success or
-- failure.
splitRowSeq
  :: Var v
  => v
  -> SeqMatch
  -> PatternRow v
  -> [([P.Pattern v], PatternRow v)]
splitRowSeq v m r@(PR (break ((==v).loc) -> (pl, sp : pr)) g b)
  = case decomposeSeqP avoid m sp of
      Cover sps -> 
        [(sps, PR (pl ++ filter refutable sps ++ pr) g b)]
      Disjoint -> []
      Overlap -> [([], r)]
  where avoid = maybe mempty freeVars g <> freeVars b
splitRowSeq _ _ r = [([], r)]

-- Renames the variables annotating the patterns in a row, for once a
-- canonical choice has been made.
renameRow :: Var v => Map v v -> PatternRow v -> PatternRow v
renameRow m (PR p0 g0 b0) = PR p g b
  where
  access k
    | Just v <- Map.lookup k m = v
    | otherwise = k
  p = (fmap.fmap) access p0
  g = changeVars m <$> g0
  b = changeVars m b0

-- Chooses a common set of variables for use when decomposing
-- patterns into multiple sub-patterns. It is too naive to simply use
-- the variables in the first row, because it may have been generated
-- by decomposing a variable or unbound pattern, which will make up
-- variables for subpatterns.
chooseVars :: Var v => [[P.Pattern v]] -> [v]
chooseVars [] = []
chooseVars ([]:rs) = chooseVars rs
chooseVars ((P.Unbound{} : _) : rs) = chooseVars rs
chooseVars (r : _) = extractVars r

-- Creates a pattern matrix from many rows with the subpatterns
-- introduced during the splitting that generated those rows. Also
-- yields an indication of the type of the variables that the
-- subpatterns match against, if possible.
buildMatrix
  :: Var v
  => [([P.Pattern v], PatternRow v)]
  -> ([(v,PType)], PatternMatrix v)
buildMatrix [] = ([], PM [])
buildMatrix vrs = (zip cvs rs, PM $ fixRow <$> vrs)
  where
  rs = fmap determineType . transpose . fmap fst $ vrs
  cvs = chooseVars $ fst <$> vrs
  fixRow (extractVars -> rvs, pr)
    = renameRow (fromListWith const . zip rvs $ cvs) pr

-- Splits a pattern matrix on a given variable, expected to be matched
-- against builtin type patterns. Yields the cases covered and
-- corresponding matrices for those cases, with types for any new
-- variables (although currently builtin patterns do not introduce
-- variables).
splitMatrixBuiltin
  :: Var v
  => v
  -> PatternMatrix v
  -> [(P.Pattern (), [(v,PType)], PatternMatrix v)]
splitMatrixBuiltin v (PM rs)
  = fmap (\(a,(b,c)) -> (a,b,c))
  . toList
  . fmap buildMatrix
  . fromListWith (++)
  $ splitRowBuiltin v =<< rs

matchPattern :: [(v,PType)] -> SeqMatch -> P.Pattern ()
matchPattern vrs = \case
    E -> sz 0
    C -> P.SequenceOp () vr Cons vr
    S -> P.SequenceOp () vr Snoc vr
    L n -> P.SequenceOp () (sz n) Concat (P.Var ())
    R n -> P.SequenceOp () (P.Var ()) Concat (sz n)
    DL _ -> P.Unbound ()
    DR _ -> P.Unbound ()
  where
  vr | [] <- vrs = P.Unbound () | otherwise = P.Var ()
  sz n = P.SequenceLiteral () . replicate n $ P.Unbound ()

-- Splits a matrix at a given variable with respect to sequence
-- patterns. Yields the appropriate patterns for the covered cases,
-- variables introduced for each case with their types, and new
-- matricies for subsequent compilation.
splitMatrixSeq
  :: Var v
  => v
  -> PatternMatrix v
  -> [(P.Pattern (), [(v,PType)], PatternMatrix v)]
splitMatrixSeq v (PM rs)
  = cases
  where
  ms = decideSeqPat $ take 1 . dropWhile ((/=v).loc) . matches =<< rs
  hint m vrs
    | m `elem` [E,C,S] = vrs
    | otherwise = (fmap.fmap) (const $ PData Rf.listRef) vrs
  cases = ms <&> \m ->
    let frs = rs >>= splitRowSeq v m
        (vrs, pm) = buildMatrix frs
    in (matchPattern vrs m, hint m vrs, pm)

-- Splits a matrix at a given variable with respect to a data type or
-- ability match. Yields a new matrix for each constructor, with
-- variables introduced and their types for each case.
splitMatrix
  :: Var v
  => v
  -> Reference
  -> NCons
  -> PatternMatrix v
  -> [(Int, [(v,PType)], PatternMatrix v)]
splitMatrix v rf cons (PM rs)
  = fmap (\(a, (b, c)) -> (a,b,c)) . (fmap.fmap) buildMatrix $ mmap
  where
  mmap = fmap (\(t,fs) -> (t, splitRow v rf t fs =<< rs)) cons

-- Monad for pattern preparation. It is a state monad carrying a fresh
-- variable source, the list of variables bound the the pattern being
-- prepared, and a variable renaming mapping.
type PPM v a = State (Word64, [v], Map v v) a

freshVar :: Var v => PPM v v
freshVar = state $ \(fw, vs, rn) ->
  let v = freshenId fw $ typed Pattern
  in (v, (fw+1, vs, rn))

useVar :: PPM v v
useVar = state $ \(avoid, v:vs, rn) -> (v, (avoid, vs, rn))

renameTo :: Var v => v -> v -> PPM v ()
renameTo to from
  = modify $ \(avoid, vs, rn) ->
      ( avoid, vs
      , insertWith (error "renameTo: duplicate rename") from to rn
      )

-- Tries to rewrite sequence patterns into a format that can be
-- matched most flexibly.
normalizeSeqP :: P.Pattern a -> P.Pattern a
normalizeSeqP (P.As a p) = P.As a (normalizeSeqP p)
normalizeSeqP (P.EffectPure a p) = P.EffectPure a $ normalizeSeqP p
normalizeSeqP (P.EffectBind a r i ps k)
  = P.EffectBind a r i (normalizeSeqP <$> ps) (normalizeSeqP k)
normalizeSeqP (P.Constructor a r i ps)
  = P.Constructor a r i $ normalizeSeqP <$> ps
normalizeSeqP (P.SequenceLiteral a ps)
  = P.SequenceLiteral a $ normalizeSeqP <$> ps
normalizeSeqP (P.SequenceOp a p0 op q0)
  = case (op, normalizeSeqP p0, normalizeSeqP q0) of
      (Cons, p, P.SequenceLiteral _ ps)
        -> P.SequenceLiteral a (p:ps)
      (Snoc, P.SequenceLiteral _ ps, p)
        -> P.SequenceLiteral a (ps ++ [p])
      (Concat, P.SequenceLiteral _ ps, P.SequenceLiteral _ qs)
        -> P.SequenceLiteral a (ps ++ qs)
      (Concat, P.SequenceLiteral _ ps, q)
        -> foldr (\p r -> P.SequenceOp a p Cons r) q ps
      (Concat, p, P.SequenceLiteral _ qs)
        -> foldl (\r q -> P.SequenceOp a r Snoc q) p qs
      (op, p, q) -> P.SequenceOp a p op q
normalizeSeqP p = p

-- Prepares a pattern for compilation, like `preparePattern`. This
-- function, however, is used when a candidate variable for a pattern
-- has already been chosen, as with an As pattern. This allows turning
-- redundant names (like with the pattern u@v) into renamings.
prepareAs :: Var v => P.Pattern a -> v -> PPM v (P.Pattern v)
prepareAs (P.Unbound _) u = pure $ P.Var u
prepareAs (P.As _ p) u = prepareAs p u <* (renameTo u =<< useVar)
prepareAs (P.Var _) u = P.Var u <$ (renameTo u =<< useVar)
prepareAs (P.Constructor _ r i ps) u = do
  P.Constructor u r i <$> traverse preparePattern ps
prepareAs (P.EffectPure _ p) u = do
  P.EffectPure u <$> preparePattern p
prepareAs (P.EffectBind _ r i ps k) u = do
  P.EffectBind u r i
    <$> traverse preparePattern ps
    <*> preparePattern k
prepareAs (P.SequenceLiteral _ ps) u = do
  P.SequenceLiteral u <$> traverse preparePattern ps
prepareAs (P.SequenceOp _ p op q) u = do
  flip (P.SequenceOp u) op
    <$> preparePattern p
    <*> preparePattern q
prepareAs p u = pure $ u <$ p

-- Prepares a pattern for compilation. This removes the existing
-- annotations and replaces them with a choice of variable that the
-- pattern is matching against. As patterns are eliminated and the
-- variables they bind are used as candidates for what that level of
-- the pattern matches against.
preparePattern :: Var v => P.Pattern a -> PPM v (P.Pattern v)
preparePattern (P.Unbound _) = P.Var <$> freshVar
preparePattern (P.Var _) = P.Var <$> useVar
preparePattern (P.As _ p) = prepareAs p =<< useVar
preparePattern p = prepareAs p =<< freshVar

buildPattern :: Bool -> Reference -> Int -> [v] -> Int -> P.Pattern ()
buildPattern effect r t vs nfields
  | effect, [] <- vps = error "too few patterns for effect bind"
  | effect = P.EffectBind () r t (init vps) (last vps)
  | otherwise = P.Constructor () r t vps
  where
  vps | length vs < nfields
      = replicate nfields $ P.Unbound ()
      | otherwise
      = P.Var () <$ vs

numberCons :: Cons -> NCons
numberCons = zip [0..]

lookupData :: Reference -> DataSpec -> Either String Cons
lookupData rf (Map.lookup rf -> Just econs)
  = case econs of
      Left _ -> Left $ "data type matching on ability: " ++ show rf
      Right cs -> Right cs
lookupData rf _ = Left $ "unknown data reference: " ++ show rf

lookupAbil :: Reference -> DataSpec -> Either String Cons
lookupAbil rf (Map.lookup rf -> Just econs)
  = case econs of
      Right _ -> Left $ "ability matching on data: " ++ show rf
      Left cs -> Right cs
lookupAbil rf _ = Left $ "unknown ability reference: " ++ show rf

compile :: Var v => DataSpec -> Ctx v -> PatternMatrix v -> Term v
compile _ _ (PM []) = placeholder () "pattern match failure"
compile spec ctx m@(PM (r:rs))
  | rowIrrefutable r
  = case guard r of
      Nothing -> body r
      Just g -> iff mempty g (body r) $ compile spec ctx (PM rs)
  | PData rf <- ty
  , rf == Rf.listRef
  = match () (var () v)
      $ buildCaseBuiltin spec ctx
     <$> splitMatrixSeq v m
  | PData rf <- ty
  , rf `member` builtinCase
  = match () (var () v)
      $ buildCaseBuiltin spec ctx
     <$> splitMatrixBuiltin v m
  | PData rf <- ty
  = case lookupData rf spec of
      Right cons ->
        match () (var () v)
          $ buildCase spec rf False cons ctx
         <$> splitMatrix v rf (numberCons cons) m
      Left err -> error err
  | PReq rfs <- ty
  = match () (var () v) $
      [ buildCasePure spec ctx tup
      | tup <- splitMatrix v undefined [(-1,1)] m
      ] ++
      [ buildCase spec rf True cons ctx tup
      | rf <- Set.toList rfs
      , Right cons <- [lookupAbil rf spec]
      , tup <- splitMatrix v rf (numberCons cons) m
      ]
  | Unknown <- ty
  = error "unknown pattern compilation type"
  where
  v = choose heuristics m
  ty = Map.findWithDefault Unknown v ctx

buildCaseBuiltin
  :: Var v
  => DataSpec
  -> Ctx v
  -> (P.Pattern (), [(v,PType)], PatternMatrix v)
  -> MatchCase () (Term v)
buildCaseBuiltin spec ctx0 (p, vrs, m)
  = MatchCase p Nothing . absChain' vs $ compile spec ctx m
  where
  vs = ((),) . fst <$> vrs
  ctx = Map.fromList vrs <> ctx0

buildCasePure
  :: Var v
  => DataSpec
  -> Ctx v
  -> (Int, [(v,PType)], PatternMatrix v)
  -> MatchCase () (Term v)
buildCasePure spec ctx0 (_, vts, m)
  = MatchCase pat Nothing . absChain' vs $ compile spec ctx m
  where
  pat = P.EffectPure () (P.Var ())
  vs = ((),) . fst <$> vts
  ctx = Map.fromList vts <> ctx0

buildCase
  :: Var v
  => DataSpec
  -> Reference
  -> Bool
  -> Cons
  -> Ctx v
  -> (Int, [(v,PType)], PatternMatrix v)
  -> MatchCase () (Term v)
buildCase spec r eff cons ctx0 (t, vts, m)
  = MatchCase pat Nothing . absChain' vs $ compile spec ctx m
  where
  pat = buildPattern eff r t vs $ cons !! t
  vs = ((),) . fst <$> vts
  ctx = Map.fromList vts <> ctx0

mkRow
  :: Var v
  => v
  -> MatchCase a (Term v)
  -> State Word64 (PatternRow v)
mkRow sv (MatchCase (normalizeSeqP -> p0) g0 (AbsN' vs b))
  = state $ \w -> case runState (prepareAs p0 sv) (w, vs, mempty) of
      (p, (w, [], rn)) -> (,w)
        $ PR (filter refutable [p])
             (changeVars rn <$> g)
             (changeVars rn b)
      _ -> error "mkRow: not all variables used"
  where
  g = case g0 of
        Just (AbsN' us g)
          | us == vs -> Just g
          | otherwise -> error "mkRow: guard variables do not match body"
        Nothing -> Nothing
        _ -> error "mkRow: impossible"
mkRow _ _ = error "mkRow: impossible"

initialize
  :: Var v
  => PType
  -> Term v
  -> [MatchCase () (Term v)]
  -> (Maybe v, (v, PType), PatternMatrix v)
initialize r sc cs
  = ( lv
    , (sv, r)
    , PM $ evalState (traverse (mkRow sv) cs) 1
    )
  where
  (lv, sv) | Var' v <- sc = (Nothing, v)
           | pv <- freshenId 0 $ typed Pattern
           = (Just pv, pv)

splitPatterns :: Var v => DataSpec -> Term v -> Term v
splitPatterns spec0 = visitPure $ \case
  Match' sc0 cs0
    | ty <- determineType $ p <$> cs0
    , (lv, scrut, pm) <- initialize ty sc cs
    , body <- compile spec (uncurry Map.singleton scrut) pm
   -> Just $ case lv of
        Just v -> let1 False [(((),v), sc)] body
        _ -> body
    where
    sc = splitPatterns spec sc0
    cs = fmap (splitPatterns spec) <$> cs0
  _ -> Nothing
  where
  p (MatchCase pp _ _) = pp
  spec = Map.insert Rf.booleanRef (Right [0,0]) spec0

builtinCase :: Set Reference
builtinCase
  = Set.fromList
  [ Rf.intRef
  , Rf.natRef
  , Rf.floatRef
  , Rf.textRef
  , Rf.charRef
  ]

determineType :: Show a => [P.Pattern a] -> PType
determineType = foldMap f
  where
  f (P.As _ p) = f p
  f P.Int{} = PData Rf.intRef
  f P.Nat{} = PData Rf.natRef
  f P.Float{} = PData Rf.floatRef
  f P.Boolean{} = PData Rf.booleanRef
  f P.Text{} = PData Rf.textRef
  f P.Char{} = PData Rf.charRef
  f P.SequenceLiteral{} = PData Rf.listRef
  f P.SequenceOp{} = PData Rf.listRef
  f (P.Constructor _ r _ _) = PData r
  f (P.EffectBind _ r _ _ _) = PReq $ Set.singleton r
  f P.EffectPure{} = PReq mempty
  f _ = Unknown
