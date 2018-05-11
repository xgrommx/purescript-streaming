module Streaming.Prelude where

import Prelude (class Eq, class Functor, class Monad, class Ord, class Show, Unit, bind, discard, flip, id, map, max, min, not, pure, show, unit, when, ($), (*), (*>), (+), (-), (/=), (<$), (<<<), (<=), (<>), (==), (>>=))
import Streaming.Internal

import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Aff.Console (CONSOLE)
import Control.Monad.Aff.Console as A
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console as E
import Control.Monad.IO.Class (class MonadIO, liftIO)
import Control.Monad.IOSync.Class (class MonadIOSync, liftIOSync)
import Control.Monad.Trans.Class (class MonadTrans, lift)
import Data.Array ((:))
import Data.Either (Either(..))
import Data.Foldable (class Foldable, foldr)
import Data.Functor.Compose (Compose(..))
import Data.Functor.Coproduct (Coproduct)
import Data.Functor.Of (Of, (:>))
import Data.Identity (Identity(..))
import Data.Lazy (Lazy, defer, force)
import Data.Maybe (Maybe(..))
import Data.Monoid (class Monoid, mempty)
import Data.Newtype as N
import Data.Sequence as Seq
import Data.Tuple (Tuple(..))

data Tuple3 a b c = Tuple3 a b c

instance showTuple3 :: (Show a, Show b, Show c) => Show (Tuple3 a b c) where
  show (Tuple3 a b c) = "Tuple3 " <> show a <> " " <> show b <> " " <> show c

fst' :: forall a b. Of a b -> a
fst' (a :> _) = a

snd' :: forall a b. Of a b -> Lazy b
snd' (_ :> b) = b

mapOf :: forall a b r. (a -> b) -> Of a r -> Of b r
mapOf f (a:> b) = (f a :> b)

_first :: forall f a a' b. Functor f => (a -> f a') -> Of a b -> f (Of a' b)
_first afb (a:>b) = map (\c -> (c:>b)) (afb a)

_second :: forall f b b' a. Functor f => (b -> f b') -> Of a b -> f (Of a b')
_second afb (a:>b) = map (\c -> (a:> defer \_ -> c)) (afb $ force b)

all :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> m (Of Boolean r)
all thus = loop true where
  loop b str = case str of
    Return r -> pure (b :> defer \_ -> r)
    Effect m -> m >>= loop b
    Step (a :> rest) -> if thus a
      then loop true $ force rest
      else do
        r <- effects $ force rest
        pure (false :> defer \_ -> r)

all_ :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> m Boolean
all_ thus = loop true where
  loop b str = case str of
    Return _ -> pure b
    Effect m -> m >>= loop b
    Step (a :> rest) -> if thus a
      then loop true $ force rest
      else pure false

any :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> m (Of Boolean r)
any thus = loop false where
  loop b str = case str of
    Return r -> pure (b :> defer \_ -> r)
    Effect m -> m >>= loop b
    Step (a :> rest) -> if thus a
      then do
        r <- effects $ force rest
        pure (true :> defer \_ -> r)
      else loop false $ force rest      

any_ :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> m Boolean
any_ thus = loop false where
  loop b str = case str of
    Return _ -> pure b
    Effect m -> m >>= loop b
    Step (a :> rest) -> if thus a
      then pure true
      else loop false $ force rest

breaks :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> Stream (Stream (Of a) m) m r
breaks thus  = loop  where
  loop stream = Effect $ do
    e <- next stream
    pure $ case e of
      Left   r      -> Return r
      Right (Tuple a p') ->
       if not (thus a)
          then Step $ map loop (yield a *> break thus p')
          else loop p'

break :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> Stream (Of a) m (Stream (Of a) m r)
break thePred = loop where
  loop str = case str of
    Return r         -> Return (Return r)
    Effect m          -> Effect $ map loop m
    Step (a :> rest) -> if (thePred a)
      then Return (Step (a :> rest))
      else Step (a :> defer \_ -> loop $ force rest)

breakWhen :: forall m a x b r. Monad m => (x -> a -> x) -> x -> (x -> b) -> (b -> Boolean) -> Stream (Of a) m r -> Stream (Of a) m (Stream (Of a) m r)
breakWhen step begin done thePred = loop0 begin
  where
    loop0 x stream = case stream of
        Return r -> pure (pure r)
        Effect mn  -> Effect $ map (loop0 x) mn
        Step (a :> rest) -> loop a (step x a) (force rest)
    loop a x stream = do
      if thePred (done x)
        then pure (yield a *> stream)
        else case stream of
          Return r -> yield a *> pure (pure r)
          Effect mn  -> Effect $ map (loop a x) mn
          Step (a' :> rest) -> do
            yield a
            loop a' (step x a') (force rest)

chain :: forall m a r. Monad m => (a -> m Unit) -> Stream (Of a) m r -> Stream (Of a) m r
chain f = loop where
  loop str = case str of
    Return r -> pure r
    Effect mn  -> Effect (map loop mn)
    Step (a :> rest) -> Effect $ do
      f a
      pure (Step (a :> (defer \_ -> loop (force rest))))

concat :: forall m f a r. Monad m => Foldable f => Stream (Of (f a)) m r -> Stream (Of a) m r
concat str = for str each

cons :: forall m a r. Monad m => a -> Stream (Of a) m r -> Stream (Of a) m r
cons a str = Step (a :> defer \_ -> str)

cycle :: forall m f r s. Monad m => Functor f => Stream f m r -> Stream f m s
cycle str = force loop where loop = defer \_ -> str *> (force loop)

drained :: forall m t a r. Monad m => Monad (t m) => MonadTrans t => t m (Stream (Of a) m r) -> t m r
drained tms = tms >>= lift <<< effects

drop :: forall m a r. Monad m => Int -> Stream (Of a) m r -> Stream (Of a) m r
drop n str | n <= 0 = str
drop n str = loop n str where
  loop 0 stream = stream
  loop m stream = case stream of
      Return r       -> Return r
      Effect ma      -> Effect (map (loop m) ma)
      Step (_ :> as) -> loop (m-1) $ force as

dropWhile :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> Stream (Of a) m r
dropWhile thePred = loop where
  loop stream = case stream of
    Return r       -> Return r
    Effect ma       -> Effect (map loop ma)
    Step (a :> as) -> if thePred a
      then loop $ force as
      else Step (a :> as)

each :: forall m f a. Monad m => Foldable f => f a -> Stream (Of a) m Unit
each = foldr (\a p -> Step (a :> (defer \_ -> p))) (Return unit)

effects :: forall m a r. Monad m => Stream (Of a) m r -> m r
effects = loop where
  loop stream = case stream of
    Return r         -> pure r
    Effect m         -> m >>= loop
    Step (_ :> rest) -> loop (force rest)

elem :: forall m a r. Monad m => Eq a => a -> Stream (Of a) m r -> m (Of Boolean r)
elem a' = loop false where
  loop true str = map (\x -> true :> defer \_ -> x) (effects str)
  loop false str = case str of
    Return r -> pure (false :> defer \_ -> r)
    Effect m -> m >>= loop false
    Step (a:> rest) ->
      if a == a'
        then map (\x -> true :> defer \_ -> x) (effects $ force rest)
        else loop false $ force rest

elem_ :: forall m a r. Monad m => Eq a => a -> Stream (Of a) m r -> m Boolean
elem_ a' = loop false where
  loop true _ = pure true
  loop false str = case str of
    Return _ -> pure false
    Effect m -> m >>= loop false
    Step (a:> rest) ->
      if a == a'
        then pure true
        else loop false $ force rest

erase :: forall m a r. Monad m => Stream (Of a) m r -> Stream Identity m r
erase = loop where
  loop str = case str of
    Return r -> Return r
    Effect m -> Effect (map loop m)
    Step (_ :> rest) -> Step (Identity (loop $ force rest))

filter  :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> Stream (Of a) m r
filter thePred = loop where
  loop str = case str of
    Return r       -> Return r
    Effect m       -> Effect (map loop m)
    Step (a :> as) -> if thePred a then Step (a :> defer \_ -> loop $ force as) else loop $ force as

filterM  :: forall m a r. Monad m => (a -> m Boolean) -> Stream (Of a) m r -> Stream (Of a) m r
filterM thePred = loop where
  loop str = case str of
    Return r       -> Return r
    Effect m       -> Effect $ map loop m
    Step (a :> as) -> Effect $ do
      bool <- thePred a
      if bool
        then pure $ Step (a :> defer \_ -> loop $ force as)
        else pure $ loop $ force as

fold_ :: forall m x a r b. Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream (Of a) m r -> m b
fold_ step begin done = map (\(a :> _) -> a) <<< fold step begin done

fold :: forall m x a b r. Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream (Of a) m r -> m (Of b r)
fold step begin done str =  fold_loop str begin
  where
    fold_loop stream x = case stream of
      Return r         -> pure ((done x) :> (defer \_ -> r))
      Effect m         -> m >>= \str' -> fold_loop str' x
      Step (a :> rest) -> fold_loop (force rest) $ step x a

foldM_ :: forall m a x b r. Monad m => (x -> a -> m x) -> m x -> (x -> m b) -> Stream (Of a) m r -> m b
foldM_ step begin done = map (\(a :> _) -> a) <<< foldM step begin done

foldM :: forall m a x b r. Monad m => (x -> a -> m x) -> m x -> (x -> m b) -> Stream (Of a) m r ->m (Of b r)
foldM step begin done str = do
    x0 <- begin
    loop str x0
  where
    loop stream x = case stream of
      Return r         -> done x >>= \b -> pure (b :> (defer \_ -> r))
      Effect m          -> m >>= \s -> loop s x
      Step (a :> rest) -> do
        x' <- step x a
        loop (force rest) x'

foldrT :: forall m t a r. Monad m => MonadTrans t => Monad (t m) => (a -> t m r -> t m r) -> Stream (Of a) m r -> t m r
foldrT step = loop where
  loop stream = case stream of
    Return r       -> pure r
    Effect m       -> lift m >>= loop
    Step (a :> as) -> step a (loop $ force as)

foldrM :: forall m a r. Monad m => (a -> m r -> m r) -> Stream (Of a) m r -> m r
foldrM step = loop where
  loop stream = case stream of
    Return r       -> pure r
    Effect m       -> m >>= loop
    Step (a :> as) -> step a (loop $ force as)

for :: forall m f a r x. Monad m => Functor f => Stream (Of a) m r -> (a -> Stream f m x) -> Stream f m r
for str0 act = loop str0 where
  loop str = case str of
    Return r         -> Return r
    Effect m          -> Effect $ map loop m
    Step (a :> rest) -> act a *> loop (force rest)

groupBy :: forall m a r. Monad m
  => (a -> a -> Boolean)
  -> Stream (Of a) m r
  -> Stream (Stream (Of a) m) m r
groupBy equals = loop  where
  loop stream = Effect $ do
        e <- next stream
        pure $ case e of
            Left   r      -> Return r
            Right (Tuple a p') -> Step $
                map loop (yield a *> span (equals a) p')

group :: forall m a r. Monad m => Eq a => Stream (Of a) m r -> Stream (Stream (Of a) m) m r
group = groupBy (==)

head :: forall m a r. Monad m => Stream (Of a) m r -> m (Of (Maybe a) r)
head str = case str of
  Return r            -> pure (Nothing :> defer \_ -> r)
  Effect m            -> m >>= head
  Step (a :> rest)    -> effects (force rest) >>= \r -> pure (Just a :> defer \_ -> r)

head_ :: forall m a r. Monad m => Stream (Of a) m r -> m (Maybe a)
head_ str = case str of
  Return _ -> pure Nothing
  Effect m -> m >>= head_
  Step (a :> _) -> pure (Just a)

intersperse :: forall m a r. Monad m => a -> Stream (Of a) m r -> Stream (Of a) m r
intersperse x str = case str of
    Return r -> Return r
    Effect m -> Effect (map (intersperse x) m)
    Step (a :> rest) -> loop a $ force rest
  where
    loop a theStr = case theStr of
      Return r -> Step (a :> defer \_ -> Return r)
      Effect m -> Effect (map (loop a) m)
      Step (b :> rest) -> Step (a :> defer \_ -> Step (x :> defer \_ -> loop b $ force rest))

iterate :: forall m a r. Monad m => (a -> a) -> a -> Stream (Of a) m r
iterate f = loop where loop a' = Effect (pure (Step (a' :> (defer \_ -> loop (f a')))))

iterateM :: forall a m r. Monad m => (a -> m a) -> m a -> Stream (Of a) m r
iterateM f = loop where
  loop ma  = Effect $ do
    a <- ma
    pure (Step (a :> defer \_ -> loop (f a)))

last :: forall m a r. Monad m => Stream (Of a) m r -> m (Of (Maybe a) r)
last = loop Nothing where
  loop mb str = case str of
    Return r            -> case mb of
      Nothing -> pure (Nothing :> defer \_ -> r)
      Just a  -> pure (Just a :> defer \_ -> r)
    Effect m            -> m >>= loop mb
    Step (a :> rest)  -> loop (Just a) $ force rest    

last_ :: forall m a r. Monad m => Stream (Of a) m r -> m (Maybe a)
last_ = loop Nothing where
  loop mb str = case str of
    Return _ -> case mb of
      Nothing -> pure Nothing
      Just a  -> pure (Just a)
    Effect m -> m >>= loop mb
    Step (a :> rest) -> loop (Just a) $ force rest

length_ :: forall m a r. Monad m => Stream (Of a) m r -> m Int
length_ = fold_ (\n _ -> n + 1) 0 id

length :: forall m a r. Monad m => Stream (Of a) m r -> m (Of Int r)
length = fold (\n _ -> n + 1) 0 id

map' :: forall m a b r. Monad m => (a -> b) -> Stream (Of a) m r -> Stream (Of b) m r
map' f =  maps (\(x :> rest) -> f x :> rest)

mapM :: forall m a r b. Monad m => (a -> m b) -> Stream (Of a) m r -> Stream (Of b) m r
mapM f = loop where
  loop str = case str of
    Return r       -> Return r
    Effect m        -> Effect (map loop m)
    Step (a :> as) -> Effect $ do
      a' <- f a
      pure (Step (a' :> defer \_ -> loop (force as)))

mapM_ :: forall m a r b. Monad m => (a -> m b) -> Stream (Of a) m r -> m r
mapM_ f = loop where
  loop str = case str of
    Return r -> pure r
    Effect m -> m >>= loop
    Step (a :> as) -> f a *> loop (force as)

mapped :: forall m f g r. Monad m => Functor f => NatM m f g -> Stream f m r -> Stream g m r
mapped = mapsM

mappedPost :: forall f m g r. Monad m => Functor g => NatM m f g -> Stream f m r -> Stream g m r
mappedPost = mapsMPost

mconcat :: forall m w r. Monad m => Monoid w => Stream (Of w) m r -> m (Of w r)
mconcat = fold (<>) mempty id

mconcat_ :: forall m w r. Monad m => Monoid w => Stream (Of w) m r -> m w
mconcat_ = fold_ (<>) mempty id

minimum_ :: forall m a r. Monad m => Ord a => Stream (Of a) m r -> m (Maybe a)
minimum_ = fold_ (\m a -> case m of 
  Nothing -> Just a
  Just a' -> Just (min a a')) Nothing (\m -> case m of 
    Nothing -> Nothing
    Just r -> Just r)

next :: forall m a r. Monad m => Stream (Of a) m r -> m (Either r (Tuple a (Stream (Of a) m r)))
next = loop where
  loop stream = case stream of
    Return r         -> pure (Left r)
    Effect m          -> m >>= loop
    Step (a :> rest) -> pure (Right (Tuple a (force rest)))

notElem :: forall m a r. Monad m => Eq a => a -> Stream (Of a) m r -> m (Of Boolean r)
notElem a' = loop true where
  loop false str = map (\x -> false :> defer \_ -> x) (effects str)
  loop true str = case str of
    Return r -> pure (true :> defer \_ -> r)
    Effect m -> m >>= loop true
    Step (a:> rest) ->
      if a == a'
        then map (\x -> false :> defer \_ -> x) (effects $ force rest)
        else loop true $ force rest

notElem_ :: forall m a r. Monad m => Eq a => a -> Stream (Of a) m r -> m Boolean
notElem_ a' = loop true where
  loop false _ = pure false
  loop true str = case str of
    Return _ -> pure true
    Effect m -> m >>= loop true
    Step (a:> rest) ->
      if a == a'
        then pure false
        else loop true $ force rest

partition :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> Stream (Of a) (Stream (Of a) m) r
partition thus = loop where
   loop str = case str of
     Return r -> Return r
     Effect m -> Effect (map loop (lift m))
     Step (a :> rest) -> if thus a
       then Step (a :> defer \_ -> loop $ force rest)
       else Effect $ do
               yield a
               pure (loop $ force rest)

partitionEithers :: forall m a b r. Monad m => Stream (Of (Either a b)) m r -> Stream (Of a) (Stream (Of b) m) r
partitionEithers =  loop where
   loop str = case str of
     Return r -> Return r
     Effect m -> Effect (map loop (lift m))
     Step (Left a :> rest) -> Step (a :> (defer \_ -> loop (force rest)))
     Step (Right b :> rest) -> Effect $ do
       yield b
       pure (loop (force rest))

product :: forall m r. Monad m => Stream (Of Int) m r -> m (Of Int r)
product = fold (*) 1 id

product_ :: forall m r. Monad m => Stream (Of Int) m Unit -> m Int
product_ = fold_ (*) 1 id

repeat :: forall m a r. Monad m => a -> Stream (Of a) m r
repeat a = force loop where loop = defer \_ -> Effect (pure (Step (a :> loop)))

repeatM :: forall m a r. Monad m => m a -> Stream (Of a) m r
repeatM ma = loop where
  loop = do
    a <- lift ma
    yield a
    loop

replicate :: forall m a. Monad m => Int -> a -> Stream (Of a) m Unit
replicate n _ | n <= 0 = pure unit
replicate n a = loop n where
  loop 0 = Return unit
  loop m = Effect (pure (Step (a :> defer \_ -> loop (m-1))))

replicateM :: forall m a. Monad m => Int -> m a -> Stream (Of a) m Unit
replicateM n _ | n <= 0 = pure unit
replicateM n ma = loop n where
  loop 0 = Return unit
  loop m = Effect $ do
    a <- ma
    pure (Step (a :> defer \_ -> loop (m-1)))

reread :: forall m a s. Monad m => (s -> m (Maybe a)) -> s -> Stream (Of a) m Unit
reread step s = loop where
  loop = Effect $ do
    m <- step s
    case m of
      Nothing -> pure (Return unit)
      Just a  -> pure (Step (a :> defer \_ -> loop))

scan :: forall m a x b r. Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream (Of a) m r -> Stream (Of b) m r
scan step begin done str = Step (done begin :> (defer \_ -> loop begin str)) where                   
  loop acc stream = do
    case stream of
      Return r -> Return r
      Effect m -> Effect (map (loop acc) m)
      Step (a :> rest) ->  let acc' = step acc a in Step (done acc' :> (defer \_ -> loop acc' (force rest)))

scanM :: forall m a x b r. Monad m => (x -> a -> m x) -> m x -> (x -> m b) -> Stream (Of a) m r -> Stream (Of b) m r
scanM step begin done str = Effect $ do
    x <- begin
    b <- done x
    pure (Step (b :> defer \_ -> loop x str))  
  where
    loop x stream = case stream of
      Return r -> Return r
      Effect m  -> Effect $ do
        stream' <- m
        pure (loop x stream')
      Step (a :> rest) -> Effect $ do
        x' <- step x a
        b   <- done x'
        pure (Step (b :> defer \_ -> loop x' $ force rest))

scanned :: forall m a x b r. Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream (Of a) m r -> Stream (Of (Tuple a b)) m r
scanned step begin done = loop Nothing begin
  where
    loop m x stream = do
      case stream of
        Return r -> pure r
        Effect mn  -> Effect $ map (loop m x) mn
        Step (a :> rest) -> do
          case m of
            Nothing -> do
              let acc = step x a
              yield (Tuple a (done acc))
              loop (Just a) acc $ force rest
            Just _ -> do
              let acc = done (step x a)
              yield (Tuple a acc)
              loop (Just a) (step x a) $ force rest

sequence :: forall m a r. Monad m => Stream (Of (m a)) m r -> Stream (Of a) m r
sequence = loop where
  loop stream = case stream of
    Return r          -> Return r
    Effect m           -> Effect $ map loop m
    Step (ma :> rest) -> Effect $ do
      a <- ma
      pure (Step (a :> defer \_ -> loop $ force rest))

-- show' :: forall m a r. Monad m => Show a => Stream (Of a) m r -> Stream (Of String) m r
-- show' = map show

sum :: forall m r. Monad m => Stream (Of Int) m r -> m (Of Int r)
sum = fold (+) 0 id

sum_ :: forall m. Monad m => Stream (Of Int) m Unit -> m Int
sum_ = fold_ (+) 0 id

span :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> Stream (Of a) m (Stream (Of a) m r)
span thePred = loop where
  loop str = case str of
    Return r         -> Return (Return r)
    Effect m          -> Effect $ map loop m
    Step (a :> rest) -> if thePred a
      then Step (a :> (defer \_ -> loop (force rest)))
      else Return (Step (a :> rest))

split :: forall m a r. Eq a => Monad m => a -> Stream (Of a) m r -> Stream (Stream (Of a) m) m r
split t  = loop  where
  loop stream = case stream of
    Return r -> Return r
    Effect m -> Effect (map loop m)
    Step (a :> rest) ->
         if a /= t
            then Step (map loop (yield a *> break (_==t) (force rest)))
            else loop $ force rest

splitAt :: forall m f r. Monad m => Functor f => Int -> Stream f m r -> Stream f m (Stream f m r)
splitAt = splitsAt

subst :: forall m f a x r. Monad m => Functor f =>  (a -> f x) -> Stream (Of a) m r -> Stream f m r
subst f s = loop s where
  loop str = case str of
    Return r         -> Return r
    Effect m         -> Effect (map loop m)
    Step (a :> rest) -> Step (loop (force rest) <$ f a)

take :: forall m f r. Monad m => Functor f => Int -> Stream f m r -> Stream f m Unit
take n0 _ | n0 <= 0 = pure unit
take n0 str = loop n0 str where
  loop 0 _ = pure unit
  loop n p =
    case p of
      Step fas -> Step (map (loop (n-1)) fas)
      Effect m -> Effect (map (loop n) m)
      Return _ -> Return unit

takeWhile :: forall m a r. Monad m => (a -> Boolean) -> Stream (Of a) m r -> Stream (Of a) m Unit
takeWhile thePred = loop where
  loop str = case str of
    Step (a :> as) -> when (thePred a) (Step (a :> defer \_ -> loop $ force as))
    Effect m -> Effect (map loop m)
    Return _ -> Return unit

takeWhileM :: forall m a r. Monad m => (a -> m Boolean) -> Stream (Of a) m r -> Stream (Of a) m Unit
takeWhileM thePred = loop where
  loop str = case str of
    Step (a :> as) -> do
      b <- lift (thePred a)
      when b (Step (a :> defer \_ -> loop $ force as))
    Effect m -> Effect (map loop m)
    Return _ -> Return unit

toList_ :: forall m a r. Monad m => Stream (Of a) m r -> m (Array a)
toList_ = fold_ (\diff a ls -> diff (a : ls)) id (\diff -> diff [])

toList :: forall m a r. Monad m => Stream (Of a) m r -> m (Of (Array a) r)
toList = fold (\diff a ls -> diff (a: ls)) id (\diff -> diff [])

uncons :: forall m a r. Monad m => Stream (Of a) m r -> m (Maybe (Tuple a (Stream (Of a) m r)))
uncons = loop where
  loop stream = case stream of
    Return _         -> pure Nothing
    Effect m         -> m >>= loop
    Step (a :> rest) -> pure (Just (Tuple a $ force rest))

unfoldr :: forall m s a r. Monad m => (s -> m (Either r (Tuple a s))) -> s -> Stream (Of a) m r
unfoldr step = loop where
  loop s0 = Effect $ do
    e <- step s0
    case e of
      Left r      -> pure (Return r)
      Right (Tuple a s) -> pure (Step (a :> defer \_ -> loop s))

untilRight :: forall m a r. Monad m => m (Either a r) -> Stream (Of a) m r
untilRight act = Effect loop where
  loop = do
    e <- act
    case e of
      Right r -> pure (Return r)
      Left a -> pure (Step (a :> defer \_ -> Effect loop))

with :: forall m f a r x. Monad m => Functor f => Stream (Of a) m r -> (a -> f x) -> Stream f m r
with s f = loop s where
  loop str = case str of
    Return r         -> Return r
    Effect m         -> Effect (map loop m)
    Step (a :> rest) -> Step (loop (force rest) <$ f a)

yield :: forall m a. Monad m => a -> Stream (Of a) m Unit
yield a = Step (a :> defer \_ -> Return unit)

zip :: forall m a b r. Monad m
    => (Stream (Of a) m r)
    -> (Stream (Of b) m r)
    -> (Stream (Of (Tuple a b)) m r)
zip = zipWith Tuple

zipWith :: forall m a b c r. Monad m
    => (a -> b -> c)
    -> (Stream (Of a) m r)
    -> (Stream (Of b) m r)
    -> (Stream (Of c) m r)
zipWith f = loop
  where
    loop str0 str1 = case str0 of
      Return r          -> Return r
      Effect m           -> Effect $ map (\str -> loop str str1) m
      Step (a :> rest0) -> case str1 of
        Return r          -> Return r
        Effect m           -> Effect $ map (loop str0) m
        Step (b :> rest1) -> Step (f a b :> defer \_ -> loop (force rest0) (force rest1))

zip3 :: forall m a b c r. Monad m
    => (Stream (Of a) m r)
    -> (Stream (Of b) m r)
    -> (Stream (Of c) m r)
    -> (Stream (Of (Tuple3 a b c)) m r)
zip3 = zipWith3 Tuple3

zipWith3 :: forall m a b c d r. Monad m =>
       (a -> b -> c -> d)
       -> Stream (Of a) m r
       -> Stream (Of b) m r
       -> Stream (Of c) m r
       -> Stream (Of d) m r
zipWith3 op = loop where
  loop str0 str1 str2 = do
    e0 <- lift (next str0)
    case e0 of
      Left r0 -> pure r0
      Right (Tuple a0 rest0) -> do
        e1 <- lift (next str1)
        case e1 of
          Left r1 -> pure r1
          Right (Tuple a1 rest1) -> do
            e2 <- lift (next str2)
            case e2 of
              Left r2 -> pure r2
              Right (Tuple a2 rest2) -> do
                yield (op a0 a1 a2)
                loop rest0 rest1 rest2

printIO :: forall m a r. MonadIO m => Show a => Stream (Of a) m r -> m r
printIO = loop where
  loop stream = case stream of
    Return r         -> pure r
    Effect m         -> m >>= loop
    Step (a :> rest) -> do
      liftIO (liftAff $ A.logShow a)
      loop (force rest)

printIOSync :: forall m a r. MonadIOSync m => Show a => Stream (Of a) m r -> m r
printIOSync = loop where
  loop stream = case stream of
    Return r         -> pure r
    Effect m         -> m >>= loop
    Step (a :> rest) -> do
      liftIOSync (liftEff $ E.logShow a)
      loop (force rest)

printEff :: forall a b e. Show a => Stream (Of a) (Eff (console :: CONSOLE | e)) b -> Eff (console :: CONSOLE | e) b
printEff = loop where
  loop stream = case stream of
    Return r         -> pure r
    Effect m         -> m >>= loop
    Step (a :> rest) -> do
      E.logShow a
      loop (force rest)

distinguish :: forall a r. (a -> Boolean) -> Of a r -> Coproduct (Of a) (Of a) r
distinguish predicate (a :> b) = N.wrap $ if predicate a then Right (a :> b) else Left (a :> b)

coproductToEither :: forall a b r. Coproduct (Of a) (Of b) r -> Of (Either a b) r
coproductToEither s = case (N.unwrap s) of
  Left (a :> r) -> Left a :> r
  Right (b :> r) -> Right b :> r

eitherToCoprodunct :: forall a b r. Of (Either a b) r -> Coproduct (Of a) (Of b) r
eitherToCoprodunct s = N.wrap $ case s of
  Left a :> r  -> Left (a :> r)
  Right b :> r -> Right (b :> r)

coproductToCompose :: forall f r. Coproduct f f r -> Compose (Of Boolean) f r
coproductToCompose x = case (N.unwrap x) of
  Right f -> Compose (true :> defer \_ -> f)
  Left f -> Compose (false :> defer \_ -> f)

composeToCoproduct :: forall f r. Compose (Of Boolean) f r -> Coproduct f f r
composeToCoproduct x = N.wrap $ case x of
  Compose (true :> f) -> Right $ force f
  Compose (false :> f) -> Left $ force f  

store :: forall m a r t. Monad m => (Stream (Of a) (Stream (Of a) m) r -> t) -> Stream (Of a) m r -> t
store f x = f (copy x)

copy :: forall m a r. Monad m => Stream (Of a) m r -> Stream (Of a) (Stream (Of a) m) r
copy = Effect <<< pure <<< loop where
  loop str = case str of
    Return r         -> Return r
    Effect m         -> Effect (map loop (lift m))
    Step (a :> rest) -> Effect (Step (a :> (defer \_ -> Return (Step (a :> (defer \_ -> loop (force rest)))))))

duplicate :: forall m r a. Monad m => Stream (Of a) m r -> Stream (Of a) (Stream (Of a) m) r
duplicate = copy

unzip :: forall m a b r. Monad m =>  Stream (Of (Tuple a b)) m r -> Stream (Of a) (Stream (Of b) m) r
unzip = loop where
 loop str = case str of
   Return r -> Return r
   Effect m -> Effect (map loop (lift m))
   Step ((Tuple a b):> rest) -> Step (a :> defer \_ -> Effect (Step (b :> (defer \_ -> Return (loop $ force rest)))))

catMaybes :: forall m a r. Monad m => Stream (Of (Maybe a)) m r -> Stream (Of a) m r
catMaybes = loop where
  loop stream = case stream of
    Return r -> Return r
    Effect m -> Effect (map loop m)
    Step (ma :> snext) -> case ma of
      Nothing -> loop $ force snext
      Just a -> Step (a :> defer \_ -> loop $ force snext)

mapMaybe :: forall m a r b. Monad m => (a -> Maybe b) -> Stream (Of a) m r -> Stream (Of b) m r
mapMaybe phi = loop where
  loop stream = case stream of
    Return r -> Return r
    Effect m -> Effect (map loop m)
    Step (a :> snext) -> case phi a of
      Nothing -> loop $ force snext
      Just b -> Step (b :> defer \_ -> loop $ force snext)

slidingWindow :: forall m a b. Monad m 
  => Int 
  -> Stream (Of a) m b 
  -> Stream (Of (Seq.Seq a)) m b
slidingWindow n = setup (max 1 n :: Int) mempty 
  where 
    window sequ str = do 
      e <- lift (next str) 
      case e of 
        Left r -> pure r
        Right (Tuple a rest) -> do 
          yield (sequ `Seq.snoc` a)
          window (Seq.drop 1 sequ `Seq.snoc` a) rest
    setup 0 sequ str = do
       yield sequ 
       window (Seq.drop 1 sequ) str 
    setup m sequ str = do 
      e <- lift $ next str 
      case e of 
        Left r ->  yield sequ *> pure r
        Right (Tuple x rest) -> setup (m-1) (sequ `Seq.snoc` x) rest

mapMaybeM :: forall m a b r. Monad m => (a -> m (Maybe b)) -> Stream (Of a) m r -> Stream (Of b) m r
mapMaybeM phi = loop where
  loop stream = case stream of
    Return r -> Return r
    Effect m -> Effect (map loop m)
    Step (a :> snext) -> Effect $ do
      flip map (phi a) $ \x -> case x of
        Nothing -> loop $ force snext
        Just b -> Step (b :> defer \_ -> loop $ force snext)









