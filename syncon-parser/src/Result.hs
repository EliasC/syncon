module Result where

import Pre

-- | An 'Applicative' representing either a value or an accumulated collection of errors
data Result e a
  = Data a
  | Error e
  deriving (Functor, Foldable, Traversable, Show)

-- | Convenience function that makes an error if the parameter is
-- distinct from 'mempty' (which is expected to represent "no error").
errorIfNonEmpty :: (Monoid e, Eq e) => e -> Result e ()
errorIfNonEmpty e
  | e == mempty = Data ()
  | otherwise = Error e

instance Semigroup e => Applicative (Result e) where
  pure = Data
  Data f <*> Data a = Data $ f a
  Error e1 <*> Error e2 = Error $ e1 <> e2
  Error e <*> _ = Error e
  _ <*> Error e = Error e

-- | This instance is technically unlawful, though the effect will matter extremely rarely.
-- The law that is broken is the following:
-- > (<*>) = ap
-- This is not true since the former will collect errors from both the left and right computation,
-- while the latter only sees error in the first computation.
instance Semigroup e => Monad (Result e) where
  return = pure
  (>>) = (*>)
  Data a >>= f = f a
  Error e >>= _ = Error e

instance Bifunctor Result where
  bimap f _ (Error e) = Error $ f e
  bimap _ f (Data a) = Data $ f a