module Data.Functor.Of where

import Prelude

import Data.Bifunctor (class Bifunctor)
import Data.Generic.Rep (class Generic)
import Data.Lazy (Lazy, defer, force)
import Data.Monoid (class Monoid, mempty)

infixr 5 Of as :>

data Of a b = Of a (Lazy b)

derive instance genericOf :: Generic (Of a b) _

instance showOf :: (Show a, Show b) => Show (Of a b) where
  show (Of a b) = show a <> ":>" <> show (force b)

instance semigroupOf :: (Semigroup a, Semigroup b) => Semigroup (Of a b) where
  append (Of m w) (Of m' w') = (m <> m') :> (w <> w')

instance monoidOf :: (Monoid a, Monoid b) => Monoid (Of a b) where
  mempty = mempty :> mempty

instance functorOf :: Functor (Of a) where
  map f (a :> x) = a :> (defer \_ -> f $ force x)

instance bifunctorOf :: Bifunctor Of where
  bimap f g (Of a b) = f a :> (defer \_ -> g $ force b)

instance applyOf :: Monoid a => Apply (Of a) where
  apply (Of m f) (Of m' x) = (m <> m') :> (defer \_ -> force f $ force x)

instance applicativeOf :: Monoid a => Applicative (Of a) where
  pure x = mempty :> (defer \_ -> x)

instance bindOf :: Monoid a => Bind (Of a) where
  bind (Of m x) f = let (Of m' y) = f $ force x in (m <> m') :> y