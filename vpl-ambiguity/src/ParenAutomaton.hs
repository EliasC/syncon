{-# LANGUAGE RecordWildCards #-}

module ParenAutomaton
( ParenNFA(..)
, fromLanguage
, RegexAlphabet(..)
, Language
, addDyck
, product
, reverse
, reduce
, trivialCoReduce
, asNFA
, FakeEdge(..)
, ppFakeEdge
, mapSta
, size
, isUnresolvablyAmbiguous
) where

import Pre hiding (product, reverse, reduce, all, from, to, sym, check)

import Data.String (fromString)

import qualified Data.HashMap.Lazy as M
import qualified Data.HashSet as S

import Util (iterateInductivelyOptM, iterateInductively)

import qualified Automaton as FA
import qualified Automaton.NFA as N
import qualified Automaton.DFA as D
import qualified Automaton.EpsilonNFA as E
import qualified Regex as R

data ParenNFA s sta a = ParenNFA
  { initial :: s
  , innerTransitions :: HashMap s (HashMap a (HashSet s))
  , openTransitions :: HashMap s (HashSet (sta, s))
  , closeTransitions :: HashMap s (HashSet (sta, s))
  , final :: s }

data RegexAlphabet nt t = NT nt | T t deriving (Eq, Generic)
instance IsString t => IsString (RegexAlphabet nt t) where
  fromString = fromString >>> T
instance (Hashable nt, Hashable t) => Hashable (RegexAlphabet nt t)
type Language nt t = HashMap nt [(R.Regex (RegexAlphabet nt t))]

fromLanguage :: forall nt t. (Eq nt, Hashable nt, Eq t, Hashable t)
             => nt -> Language nt t -> ParenNFA Int (Int, Int) t
fromLanguage startNT language = renumber complete
  where
    nfas = M.mapWithKey toMinimalDFA language
    toMinimalDFA k = fmap (R.toAutomaton >>> E.determinize >>> D.minimize)
      >>> fmap (D.renumber >>> fst)
      >>> zip [(1::Int)..]
      >>> fmap (\(i, dfa) -> FA.mapState (k, i, ) dfa & D.asNFA)

    initials = foldMap (N.initial >>> S.singleton) <$> nfas
    finals = foldMap N.final <$> nfas

    allTransitions = foldMap (fmap N.transitions) nfas
      & foldl N.mergeTransitions M.empty
      & toTriples
    classifyTransition (s1, NT nt, s2) = Left (s1, nt, s2)
    classifyTransition (s1, T t, s2) = Right (s1, t, s2)
    (ntTransitions, tTransitions) = classifyTransition <$> allTransitions
      & partitionEithers

    mkOpen (s1, nt, s2) = M.lookupDefault S.empty nt initials
      & S.map ((s1, s2),)
      & M.singleton s1
    mkClose (s1, nt, s2) = M.lookupDefault S.empty nt finals
      & S.toMap
      & (S.singleton ((s1, s2), s2) <$)

    initialState = (startNT, -1, 0)
    finalState = (startNT, -1, 1)
    topTransition = (initialState, startNT, finalState)
    complete = ParenNFA
      { innerTransitions = fromTriples tTransitions
      , openTransitions = mkOpen <$> (topTransition : ntTransitions)
        & foldl (M.unionWith S.union) M.empty
      , closeTransitions = mkClose <$> (topTransition : ntTransitions)
        & foldl (M.unionWith S.union) M.empty
      , initial = initialState
      , final = finalState }

    renumber :: (Eq s, Hashable s) => ParenNFA s (s, s) a -> ParenNFA Int (Int, Int) a
    renumber nfa@ParenNFA{..} = ParenNFA
      { initial = convert initial
      , final = convert final
      , innerTransitions = M.toList innerTransitions
        & fmap (convert *** fmap (S.map convert))
        & M.fromList
      , openTransitions = M.toList openTransitions
        & fmap (convert *** S.map ((convert *** convert) *** convert))
        & M.fromList
      , closeTransitions = M.toList closeTransitions
        & fmap (convert *** S.map ((convert *** convert) *** convert))
        & M.fromList }
      where
        convert s = M.lookup s translationMap
          & compFromJust "ParenAutomaton.fromLanguage.renumber.convert" "missing state"
        translationMap = M.fromList $ S.toList (states nfa) `zip` [1..]

states :: (Eq s, Hashable s) => ParenNFA s sta a -> HashSet s
states ParenNFA{..} = S.fromList (initial : final : inners ++ opens ++ closes)
  where
    inners = toTriples innerTransitions
      & concatMap (\(s1, _, s2) -> [s1, s2])
    opens = M.keys openTransitions
      ++ (S.toList `concatMap` M.elems openTransitions & fmap snd)
    closes = M.keys closeTransitions
      ++ (S.toList `concatMap` M.elems closeTransitions & fmap snd)

toTriples :: forall a b c. HashMap a (HashMap b (HashSet c)) -> [(a, b, c)]
toTriples trs = do
  (a, bs) <- M.toList trs
  (b, cs) <- M.toList bs
  c <- S.toList cs
  return $ (a, b, c)

fromTriples :: forall a b c. (Eq a, Hashable a, Eq b, Hashable b, Eq c, Hashable c)
            => [(a, b, c)] -> HashMap a (HashMap b (HashSet c))
fromTriples = fmap (\(a, b, c) -> M.singleton a $ M.singleton b $ S.singleton c)
  >>> foldl (M.unionWith $ M.unionWith S.union) M.empty

toTriples' :: HashMap a (HashSet (b, c)) -> [(a, b, c)]
toTriples' m = do
  (s1, stas) <- M.toList m
  (sta, s2) <- S.toList stas
  return (s1, sta, s2)

fromTriples' :: (Eq a, Hashable a, Eq b, Hashable b, Eq c, Hashable c)
             => [(a, b, c)] -> HashMap a (HashSet (b, c))
fromTriples' = fmap (\(s1, sta, s2) -> (s1, S.singleton (sta, s2)))
  >>> M.fromListWith S.union

addDyck :: (Eq s, Hashable s, Eq sta, Hashable sta) => ParenNFA s sta a -> ParenNFA s (Maybe sta) a
addDyck nfa@ParenNFA{initial, openTransitions, closeTransitions, final} = nfa
  { openTransitions = S.map (first Just) <$> openTransitions
    & M.unionWith S.union addedTransitions
  , closeTransitions = S.map (first Just) <$> closeTransitions
    & M.unionWith S.union addedTransitions}
  where
    addedTransitions = states nfa
      & S.delete initial
      & S.delete final
      & S.toMap
      & M.mapWithKey (\k _ -> S.singleton (Nothing, k))

mapSta :: (Eq s, Hashable s, Eq stb, Hashable stb)
       => (sta -> stb) -> ParenNFA s sta a -> ParenNFA s stb a
mapSta f nfa@ParenNFA{openTransitions, closeTransitions} = nfa
  { openTransitions = S.map (first f) <$> openTransitions
  , closeTransitions = S.map (first f) <$> closeTransitions }

data ProductState s sta a = ProductState
  { inners :: HashMap s (HashMap a (HashSet s))
  , opens :: HashMap s (HashSet (sta, s))
  , closes :: HashMap s (HashSet (sta, s)) }

instance (Eq s, Hashable s, Eq sta, Hashable sta, Eq a, Hashable a) => Semigroup (ProductState s sta a) where
  ProductState i1 o1 c1 <> ProductState i2 o2 c2 = ProductState
    (M.unionWith (M.unionWith S.union) i1 i2)
    (M.unionWith S.union o1 o2)
    (M.unionWith S.union c1 c2)
instance (Eq s, Hashable s, Eq sta, Hashable sta, Eq a, Hashable a) => Monoid (ProductState s sta a) where
  mempty = ProductState mempty mempty mempty
  mappend = (<>)

product :: (Eq s, Hashable s, Eq sta, Hashable sta, Eq a, Hashable a)
        => ParenNFA s sta a -> ParenNFA s sta a -> ParenNFA (s, s) (sta, sta) a
product nfa1 nfa2 = ParenNFA
  { initial = (i1, i2)
  , final = (f1, f2)
  , innerTransitions = inners foundTransitions
  , openTransitions = opens foundTransitions
  , closeTransitions = closes foundTransitions }
  where
    ParenNFA{initial = i1, final = f1, innerTransitions = it1, openTransitions = ot1, closeTransitions = ct1} = nfa1
    ParenNFA{initial = i2, final = f2, innerTransitions = it2, openTransitions = ot2, closeTransitions = ct2} = nfa2

    findTransitions s@(s1, s2) = do
      let is = M.intersectionWith cartesianProduct
                 (M.lookupDefault M.empty s1 it1)
                 (M.lookupDefault M.empty s2 it2)
          os = cartesianProduct'
                 (M.lookupDefault S.empty s1 ot1)
                 (M.lookupDefault S.empty s2 ot2)
          cs = cartesianProduct'
                 (M.lookupDefault S.empty s1 ct1)
                 (M.lookupDefault S.empty s2 ct2)
          newStates = fold is `S.union` S.map snd os `S.union` S.map snd cs

      addTransitions $ ProductState
        { inners = M.singleton s is
        , opens = M.singleton s os
        , closes = M.singleton s cs }

      return newStates

    foundTransitions = execState
      (iterateInductivelyOptM findTransitions $ S.singleton (i1, i2))
      (ProductState M.empty M.empty M.empty)

    cartesianProduct :: (Eq a, Hashable a, Eq b, Hashable b)
                     => HashSet a -> HashSet b -> HashSet (a, b)
    cartesianProduct as bs = (,) <$> S.toList as <*> S.toList bs & S.fromList

    cartesianProduct' :: ( Eq a, Hashable a, Eq sta, Hashable sta
                         , Eq b, Hashable b, Eq stb, Hashable stb )
                      => HashSet (sta, a) -> HashSet (stb, b) -> HashSet ((sta, stb), (a, b))
    cartesianProduct' as bs = (\(sta, a) (stb, b) -> ((sta, stb), (a, b)))
      <$> S.toList as <*> S.toList bs & S.fromList

    addTransitions transitions = modify (mappend transitions)

reverse :: (Eq s, Hashable s, Eq sta, Hashable sta, Eq a, Hashable a)
        => ParenNFA s sta a -> ParenNFA s sta a
reverse ParenNFA{..} = ParenNFA
  { initial = final
  , final = initial
  , innerTransitions = toTriples innerTransitions
    & fmap (\(a, b, c) -> (c, b, a))
    & fromTriples
  , openTransitions = toTriples' closeTransitions
    & fmap (\(a, b, c) -> (c, b, a))
    & fromTriples'
  , closeTransitions = toTriples' openTransitions
    & fmap (\(a, b, c) -> (c, b, a))
    & fromTriples' }

-- This removes a few obviously not co-reachable states, namely those that don't have a path to the
-- final state even when we ignore the stack
trivialCoReduce :: forall s sta a. (Eq s, Hashable s, Eq sta, Hashable sta, Eq a, Hashable a)
                => ParenNFA s sta a -> ParenNFA s sta a
trivialCoReduce nfa@ParenNFA{..} = nfa
  { innerTransitions = toTriples innerTransitions
    & filter isCoReachable
    & fromTriples
  , openTransitions = toTriples' openTransitions
    & filter isCoReachable
    & fromTriples'
  , closeTransitions = toTriples' closeTransitions
    & filter isCoReachable
    & fromTriples' }
  where
    revInner = toTriples innerTransitions
      & fmap (\(s1, _, s2) -> (s2, S.singleton s1))
    revOpen = toTriples' openTransitions
      & fmap (\(s1, _, s2) -> (s2, S.singleton s1))
    revClose = toTriples' closeTransitions
      & fmap (\(s1, _, s2) -> (s2, S.singleton s1))
    revMap = M.fromListWith S.union $ revInner ++ revOpen ++ revClose
    coReachable = iterateInductively (\s -> M.lookupDefault S.empty s revMap) $ S.singleton final
    isCoReachable :: forall x. (s, x, s) -> Bool
    isCoReachable (s1, _, s2) = S.member s1 coReachable && S.member s2 coReachable

data ReduceState s = ReduceState
  { _all :: HashSet (s, s)
  , _lToR :: HashMap s (HashSet s)
  , _rToL :: HashMap s (HashSet s) }

instance (Eq s, Hashable s) => Semigroup (ReduceState s) where
  ReduceState a1 l1 r1 <> ReduceState a2 l2 r2 = ReduceState
    (a1 <> a2)
    (M.unionWith S.union l1 l2)
    (M.unionWith S.union r1 r2)
instance (Eq s, Hashable s) => Monoid (ReduceState s) where
  mempty = ReduceState mempty mempty mempty
  mappend = (<>)

type ReduceM s a = Reader (ReduceState s) a

data TransitionState s sta a = TransitionState
  { _states :: HashSet s
  , _open :: HashMap s (HashSet (sta, s))
  , _close :: HashMap s (HashSet (sta, s))
  , _inner :: HashMap s (HashMap a (HashSet s)) }

-- TODO: I suspect this function could be written much nicer with something relational
-- TODO: should maybe openTransitions and closeTransitions have the form (a -> b -> c) instead of (a -> (b, c))? Seems to be the way that it is used
reduce :: forall s sta a. (Eq s, Hashable s, Eq sta, Hashable sta, Eq a, Hashable a)
       => ParenNFA s sta a -> ParenNFA (s, s) (sta, s) a
reduce nfa@ParenNFA{..} = ParenNFA
  { initial = initialState
  , openTransitions = _open transitions
  , closeTransitions = _close transitions
  , innerTransitions = _inner transitions
  , final = finalState }
  where
    initialState = (initial, final)
    finalState = (final, final)

    innerMap = fold <$> innerTransitions
    innerAfter s = M.lookupDefault S.empty s innerMap & S.toList

    openMap = toTriples' openTransitions
      & fmap (\(a, b, c) -> (c, M.singleton b $ S.singleton a))
      & M.fromListWith (M.unionWith S.union)
    openBefore s = M.lookupDefault M.empty s openMap

    closeMap = toTriples' closeTransitions
      & fmap (\(a, b, c) -> (a, M.singleton b $ S.singleton c))
      & M.fromListWith (M.unionWith S.union)
    closeAfter s = M.lookupDefault M.empty s closeMap

    findNewWellMatched :: (s, s) -> ReduceM s [(s, s)]
    findNewWellMatched (s1, s2) = do
      after <- fmap (s1,) <$> lToR s2
      before <- fmap (,s2) <$> rToL s1
      let inner = (s1,) <$> innerAfter s2
          wm = M.intersectionWith
                 (\a b -> (,) <$> S.toList a <*> S.toList b)
                 (openBefore s1)
                 (closeAfter s2)
             & fold
      return $ after <> before <> inner <> wm

    wellMatched = states nfa
      & S.map (identity &&& identity)
      & iterateInductivelyR findNewWellMatched

    qFromP = toList wellMatched & fmap (second S.singleton) & M.fromListWith S.union
    findTransitions (p, q) = do
      forM_ (M.lookupDefault S.empty p openTransitions) $ \(gamma, p') -> do
        forM_ (M.lookupDefault S.empty p' qFromP) $ \q' -> do
          let existsS = M.lookupDefault S.empty q' closeTransitions
                & any (\(gamma', s) -> gamma == gamma' && S.member (s, q) wellMatched)
          when existsS $ do
            addOpen ((p, q), (gamma, q), (p', q'))
      when (p == q) $ do
        forM_ (M.lookupDefault S.empty p closeTransitions) $ \(gamma, p') -> do
          forM_ (M.lookupDefault S.empty p' qFromP) $ \q' -> do
            addClose ((p, p), (gamma, q'), (p', q'))
      forM_ (M.lookupDefault M.empty p innerTransitions & M.toList) $ \(a, ps') -> do
        forM_ (S.map (,q) ps' & S.intersection wellMatched) $ \to -> do
          addInner ((p, q), a, to)
      gets _states

    transitions = execState
      (iterateInductivelyOptM findTransitions (S.singleton initialState))
      (TransitionState mempty mempty mempty mempty)

    addOpen :: ((s, s), (sta, s), (s, s)) -> State (TransitionState (s, s) (sta, s) a) ()
    addOpen (from, sta, to) = modify $ \ts@TransitionState{_open, _states} -> ts
      { _open = M.insertWith S.union from (S.singleton (sta, to)) _open
      , _states = S.insert to _states }
    addClose :: ((s, s), (sta, s), (s, s)) -> State (TransitionState (s, s) (sta, s) a) ()
    addClose (from, sta, to) = modify $ \ts@TransitionState{_close, _states} -> ts
      { _close = M.insertWith S.union from (S.singleton (sta, to)) _close
      , _states = S.insert to _states }
    addInner :: ((s, s), a, (s, s)) -> State (TransitionState (s, s) (sta, s) a) ()
    addInner (from, a, to) = modify $ \ts@TransitionState{_inner, _states} -> ts
      { _inner = M.insertWith (M.unionWith S.union) from (M.singleton a $ S.singleton to) _inner
      , _states = S.insert to _states }

    iterateInductivelyR :: forall x. (Eq x, Hashable x)
                        => ((x, x) -> ReduceM x [(x, x)]) -> HashSet (x, x) -> HashSet (x, x)
    iterateInductivelyR f init = recur mempty init
      where
        recur :: ReduceState x -> HashSet (x, x) -> HashSet (x, x)
        recur prev new
          | S.null new = _all prev
          | otherwise =
            let all = prev <> mkReduceState new
                next = S.toList new & traverse f & (`runReader` all) & concat & S.fromList
                newNext = next `S.difference` _all all
            in recur all newNext

    mkReduceState ss = ReduceState
      { _all = ss
      , _lToR = S.toList ss & fmap (second S.singleton) & M.fromListWith S.union
      , _rToL = S.toList ss & fmap (swap >>> second S.singleton) & M.fromListWith S.union }

    lToR :: s -> ReduceM s [s]
    lToR s = asks (_lToR >>> M.lookupDefault S.empty s >>> S.toList)
    rToL :: s -> ReduceM s [s]
    rToL s = asks (_rToL >>> M.lookupDefault S.empty s >>> S.toList)

asNFA :: (Eq s, Hashable s, Eq sta, Hashable sta, Eq a, Hashable a) => ParenNFA s sta a -> N.NFA s (FakeEdge sta a)
asNFA ParenNFA{..} = N.NFA
  { N.initial = initial
  , N.final = S.singleton final
  , N.transitions = mapKey Inner <$> innerTransitions
    & N.mergeTransitions (toMap Push <$> openTransitions)
    & N.mergeTransitions (toMap Pop <$> closeTransitions) }
  where
    mapKey f = M.toList >>> fmap (first f) >>> M.fromList
    toMap f = S.toList >>> fmap (f *** S.singleton) >>> M.fromListWith S.union

data FakeEdge sta a = Push sta | Pop sta | Inner a deriving (Eq, Show, Generic)
instance (Hashable sta, Hashable a) => Hashable (FakeEdge sta a)

ppFakeEdge :: (Show sta, Show a) => FakeEdge sta a -> Text
ppFakeEdge (Inner a) = show a
ppFakeEdge e = show e

data Size = Size { numStates :: Int, numInner :: Int, numOpen :: Int, numClose :: Int } deriving Show

size :: (Eq s, Hashable s) => ParenNFA s sta a -> Size
size nfa@ParenNFA{..} = Size
  { numStates = S.size $ states nfa
  , numInner = foldMap (foldMap $ S.size >>> Sum) innerTransitions & getSum
  , numOpen = foldMap (S.size >>> Sum) openTransitions & getSum
  , numClose = foldMap (S.size >>> Sum) closeTransitions & getSum }

isUnresolvablyAmbiguous :: (Eq s, Hashable s, Eq sta, Hashable sta, Eq a, Hashable a)
                        => ParenNFA s sta a -> Bool
isUnresolvablyAmbiguous original =
  product (mapSta Just original) (addDyck original)
  & reverse & reduce & reverse
  & reduce
  & trivialCoReduce -- TODO: something is not working the way I think it should if this makes changes, which it does
  & check
  where
    -- NOTE: I believe I should not need to check both open and close transitions, since they must have been pushed to be popped, and we have a trimmed automaton
    check nfa@ParenNFA{openTransitions} = -- TODO: for my test case it was enough to check states, maybe it always will be?
      any (fst >>> fst >>> uncurry (/=)) (states nfa)
      || any (\(_, sym, _) -> uncurry (/=) . fst $ fst sym) (toTriples' openTransitions)