module Streaming.Internal (
  -- * The free monad transformer
  -- $stream
  Stream (..)
  , NatM
  -- * Introducing a stream
  , unfold
  , replicates
  , repeats
  , repeatsM
  , effect
  , wrap
  , yields
  , streamBuild
  -- , cycles
  -- , delays
  , never
  , untilJust

  -- * Eliminating a stream
  , intercalates
  , concats
  , iterT
  , iterTM
  , destroy
  , streamFold

  -- * Inspecting a stream wrap by wrap
  , inspect

  -- * Transforming streams
  , maps
  , mapsM
  , mapsPost
  , mapsMPost
  , hoistUnexposed
  , decompose
  , mapsM_
  , run
  , distribute
  , groups
--    , groupInL

  -- *  Splitting streams
  , chunksOf
  , splitsAt
  , takes
  , cutoff
  -- , period
  -- , periods

  -- * Zipping and unzipping streams
  , zipsWith
  , zipsWith'
  , zips
  , unzips
  , interleaves
  , separate
  , unseparate
  , expand
  , expandPost


  -- * Assorted Data.Functor.x help
  , switch

  -- *  For use in implementation
  , unexposed
  , hoistExposed
  , hoistExposedPost
  , destroyExposed

  ) where

import Prelude

import Control.Alt (class Alt)
import Control.Alternative (class Alternative)
import Control.Apply (lift2)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Error.Class (class MonadError, class MonadThrow, catchError, throwError)
import Control.Monad.IO.Class (class MonadIO, liftIO)
import Control.Monad.IOSync.Class (class MonadIOSync, liftIOSync)
import Control.Monad.Morph (class MFunctor, class MMonad, hoist)
import Control.Monad.Reader (class MonadAsk, class MonadReader, ask, lift, local)
import Control.Monad.State (class MonadState, state)
import Control.Monad.Trans.Class (class MonadTrans)
import Control.MonadPlus (class MonadPlus)
import Control.MonadZero (class MonadZero)
import Control.Plus (class Plus)
import Data.Either (Either(..))
import Data.Functor.Compose (Compose(..))
import Data.Functor.Coproduct (Coproduct(..))
import Data.Generic.Rep (class Generic)
import Data.Lazy (defer, force)
import Data.Maybe (Maybe(..))
import Data.Monoid (class Monoid, mempty)
import Data.Newtype as N
import Data.Tuple (Tuple(..))

type NatM m f g = forall a. f a -> m (g a)

data Stream f m r = Step (f (Stream f m r)) | Effect (m (Stream f m r)) | Return r

derive instance genericStream :: Generic (Stream f m r) _

instance functorStream :: (Functor f, Monad m) => Functor (Stream f m) where
  map f = loop where
    loop stream = case stream of
      Return r -> Return (f r)
      Effect m  -> Effect $ do 
        stream' <- m
        pure (loop stream')
      Step g -> Step (map loop g)

instance applyStream :: (Functor f, Monad m) => Apply (Stream f m) where
  apply = ap

instance applicativeStream :: (Functor f, Monad m) => Applicative (Stream f m) where
  pure = Return

instance bindStream :: (Functor f, Monad m) => Bind (Stream f m) where
  bind stream f =
    loop stream where
    loop stream0 = case stream0 of
      Step fstr -> Step (map loop fstr)
      Effect m   -> Effect (map loop m)
      Return r  -> f r

instance monadStream :: (Functor f, Monad m) => Monad (Stream f m)

instance altStream :: (Applicative f, Monad m) => Alt (Stream f m) where
  alt str str' = zipsWith' lift2 str str

instance plusStream :: (Applicative f, Monad m) => Plus (Stream f m) where
  empty = never

instance alternativeStream :: (Applicative f, Monad m) => Alternative (Stream f m)

instance semigroupStream :: (Functor f, Monad m, Semigroup w) => Semigroup (Stream f m w) where
  append a b = a >>= \w -> map (w <> _) b

instance monoidStream :: (Functor f, Monad m, Monoid w) => Monoid (Stream f m w) where
  mempty = pure mempty

instance monadZeroStream :: (Applicative f, Monad m) => MonadZero (Stream f m)

instance monadPlusStream :: (Applicative f, Monad m) => MonadPlus (Stream f m)

instance monadTransStream :: MonadTrans (Stream f) where
  lift = Effect <<< map Return

instance mFunctorStream :: Functor f => MFunctor (Stream f) where
  hoist trans = loop  where
    loop stream = case stream of
      Return r  -> Return r
      Effect m  -> Effect (trans (map loop m))
      Step f    -> Step (map loop f)

instance  mMonadStream :: Functor f => MMonad (Stream f) where
  embed phi = loop where
    loop stream = case stream of
      Return r -> Return r
      Effect  m -> phi m >>= loop
      Step   f -> Step (map loop f)

instance monadEffStream :: (MonadEff e m, Functor f) => MonadEff e (Stream f m) where
  liftEff = Effect <<< map Return <<< liftEff

instance monadAffStream :: (MonadAff e m, Functor f) => MonadAff e (Stream f m) where
  liftAff = Effect <<< map Return <<< liftAff

instance monadIOStream :: (MonadIO m, Functor f) => MonadIO (Stream f m) where
  liftIO = Effect <<< map Return <<< liftIO

instance monadIOSyncStream :: (MonadIOSync m, Functor f) => MonadIOSync (Stream f m) where
  liftIOSync = Effect <<< map Return <<< liftIOSync

instance monadAskStream :: (Functor f, MonadAsk r m) => MonadAsk r (Stream f m) where
  ask = lift ask

instance monadReaderStream :: (Functor f, MonadReader r m) => MonadReader r (Stream f m) where
  local f = hoist (local f)

instance monadStateStream :: (Functor f, MonadState s m) => MonadState s (Stream f m) where
  state = lift <<< state

instance monadThrowStream :: (Functor f, MonadThrow e m) => MonadThrow e (Stream f m) where
  throwError = lift <<< throwError

instance monadErrorStream :: (Functor f, MonadError e m) => MonadError e (Stream f m) where
  catchError str f = loop str where
    loop x = case x of
      Return r -> Return r
      Effect m -> Effect $ map loop m `catchError` (pure <<< f)
      Step g -> Step (map loop g)

-------------------------------------------------------------------------------------------

inspect :: forall m f r. Monad m => Stream f m r -> m (Either r (f (Stream f m r)))
inspect = loop where
  loop stream = case stream of
    Return r -> pure (Left r)
    Effect m  -> m >>= loop
    Step fs  -> pure (Right fs)

zipsWith' :: forall f g h m r. Monad m => (forall x y p . (x -> y -> p) -> f x -> g y -> h p) -> Stream f m r -> Stream g m r -> Stream h m r
zipsWith' phi = loop
  where
    loop s t = case s of
       Return r -> Return r
       Step fs -> case t of
         Return r -> Return r
         Step gs -> Step $ phi loop fs gs
         Effect n -> Effect $ map (loop s) n
       Effect m -> Effect $ map (flip loop t) m

destroy:: forall f m r b. Functor f => Monad m => Stream f m r -> (f b -> b) -> (m b -> b) -> (r -> b) -> b
destroy stream0 construct theEffect done = theEffect (loop stream0) where
  loop stream = case stream of
    Return r -> pure (done r)
    Effect m -> m >>= loop
    Step fs -> pure (construct (map (theEffect <<< loop) fs))

streamFold :: forall f m r b. Functor f => Monad m => (r -> b) -> (m b -> b) ->  (f b -> b) -> Stream f m r -> b
streamFold done theEffect construct stream  = destroy stream construct theEffect done

streamBuild :: forall f m r. (forall b . (r -> b) -> (m b -> b) -> (f b -> b) ->  b) ->  Stream f m r
streamBuild = \phi -> phi Return Effect Step

unfold :: forall m f s r. Monad m => Functor f => (s -> m (Either r (f s))) -> s -> Stream f m r
unfold step = loop where
  loop s0 = Effect $ do
    e <- step s0
    case e of
      Left r -> pure (Return r)
      Right fs -> pure (Step (map loop fs))

maps :: forall m f g r. Monad m => Functor f => f ~> g -> Stream f m r -> Stream g m r
maps phi = loop where
  loop stream = case stream of
    Return r  -> Return r
    Effect m   -> Effect (map loop m)
    Step f    -> Step (phi (map loop f))

mapsM :: forall f m r g. Monad m => Functor f => NatM m f g -> Stream f m r -> Stream g m r
mapsM phi = loop where
  loop stream = case stream of
    Return r  -> Return r
    Effect m   -> Effect (map loop m)
    Step f    -> Effect (map Step (phi (map loop f)))

mapsPost :: forall m f g r. Monad m => Functor g => f ~> g -> Stream f m r -> Stream g m r
mapsPost phi = loop where
  loop stream = case stream of
    Return r -> Return r
    Effect m -> Effect (map loop m)
    Step f -> Step $ map loop $ phi f

mapsMPost :: forall m f g r. Monad m => Functor g => NatM m f g -> Stream f m r -> Stream g m r
mapsMPost phi = loop where
  loop stream = case stream of
    Return r -> Return r
    Effect m -> Effect (map loop m)
    Step f -> Effect $ map (Step <<< map loop) (phi f)    

decompose :: forall f m r . Monad m => Functor f => Stream (Compose m f) m r -> Stream f m r
decompose = loop where
  loop stream = case stream of
    Return r -> Return r
    Effect m ->  Effect (map loop m)
    Step (Compose mstr) -> Effect $ do
      str <- mstr
      pure (Step (map loop str))

run :: forall m r. Monad m => Stream m m r -> m r
run = loop where
  loop stream = case stream of
    Return r -> pure r
    Effect  m -> m >>= loop
    Step mrest -> mrest >>= loop

mapsM_ :: forall f m r. Functor f => Monad m => f ~> m -> Stream f m r -> m r
mapsM_ f = run <<< maps f

intercalates :: forall m t r x . Monad m => Monad (t m) => MonadTrans t => t m x -> Stream (t m) m r -> t m r
intercalates sep = go0
  where
    go0 f = case f of
      Return r -> pure r
      Effect m -> lift m >>= go0
      Step fstr -> do
        f' <- fstr
        go1 f'
    go1 f = case f of
      Return r -> pure r
      Effect m     -> lift m >>= go1
      Step fstr ->  do
        _ <- sep
        f' <- fstr
        go1 f'

iterTM :: forall f m t a. Functor f => Monad m => MonadTrans t => Monad (t m) => (f (t m a) -> t m a) -> Stream f m a -> t m a
iterTM out stream = destroyExposed stream out (join <<< lift) pure

iterT :: forall f m a. Functor f => Monad m => (f (m a) -> m a) -> Stream f m a -> m a
iterT out stream = destroyExposed stream out join pure

concats :: forall m f r. Monad m => Functor f => Stream (Stream f m) m r -> Stream f m r
concats  = loop where
  loop stream = case stream of
    Return r -> pure r
    Effect m -> lift m >>= loop
    Step fs  -> fs >>= loop

splitsAt :: forall m f r. Monad m => Functor f => Int -> Stream f m r -> Stream f m (Stream f m r)
splitsAt  = loop  where
  loop n stream
    | n <= 0 = Return stream
    | otherwise = case stream of
        Return r       -> Return (Return r)
        Effect m       -> Effect (map (loop n) m)
        Step fs        -> case n of
          0 -> Return (Step fs)
          _ -> Step (map (loop (n-1)) fs)

takes :: forall m f r. Monad m => Functor f => Int -> Stream f m r -> Stream f m Unit
takes n = void <<< splitsAt n

chunksOf ::forall m f r. Monad m => Functor f => Int -> Stream f m r -> Stream (Stream f m) m r
chunksOf n0 = loop where
  loop stream = case stream of
    Return r  -> Return r
    Effect m  -> Effect (map loop m)
    Step fs   -> Step (Step (map (map loop <<< splitsAt (n0-1)) fs))

distribute :: forall m f t r. Monad m => Functor f => MonadTrans t => MFunctor t => Monad (t (Stream f m)) => Stream f (t m) r -> t (Stream f m) r
distribute = loop where
  loop stream = case stream of
    Return r     -> lift (Return r)
    Effect tmstr -> hoist lift tmstr >>= loop
    Step fstr    -> join (lift (Step (map (Return <<< loop) fstr)))

repeats :: forall m f r. Monad m => Functor f => f Unit -> Stream f m r
repeats f = loop where
  loop = Effect (pure (Step (map (\_ -> loop) f)))        

repeatsM :: forall m f r. Monad m => Functor f => m (f Unit) -> Stream f m r
repeatsM mf = loop where
  loop = Effect $ do
     f <- mf
     pure $ Step $ map (\_ -> loop) f

replicates :: forall m f. Monad m => Functor f => Int -> f Unit -> Stream f m Unit
replicates n f = splitsAt n (repeats f) *> pure unit

hoistUnexposed :: forall m f r n. Monad m => Functor f => m ~> n -> Stream f m r -> Stream f n r
hoistUnexposed trans = force loop where
  loop = defer \_ -> Effect <<< trans <<< inspectC (pure <<< Return) (pure <<< Step <<< map (force loop))

inspectC :: forall m a r f. Monad m => (r -> m a) -> (f (Stream f m r) -> m a) -> Stream f m r -> m a
inspectC f g = loop where
  loop (Return r) = f r
  loop (Step x) = g x
  loop (Effect m) = m >>= loop

hoistExposed :: forall f m n a. Functor m => Functor f => m ~> n -> Stream f m a -> Stream f n a
hoistExposed trans = loop where
  loop stream = case stream of
    Return r  -> Return r
    Effect m  -> Effect (trans (map loop m))
    Step f    -> Step (map loop f)

hoistExposedPost :: forall n f m a. Functor n => Functor f => m ~> n -> Stream f m a -> Stream f n a
hoistExposedPost trans = loop where
  loop stream = case stream of
    Return r -> Return r
    Effect m -> Effect (map loop (trans m))
    Step f -> Step (map loop f)

destroyExposed :: forall f m r b. Functor f => Monad m => Stream f m r -> (f b -> b) -> (m b -> b) -> (r -> b) -> b
destroyExposed stream0 construct theEffect done = loop stream0 where
  loop stream = case stream of
    Return r -> done r
    Effect m -> theEffect (map loop m)
    Step fs  -> construct (map loop fs)

unexposed :: forall f m r. Functor f => Monad m => Stream f m r -> Stream f m r
unexposed = Effect <<< loop where
  loop stream = case stream of
    Return r -> pure (Return r)
    Effect  m -> m >>= loop
    Step   f -> pure (Step (map (Effect <<< loop) f))

wrap :: forall m f r. Monad m => Functor f => f (Stream f m r) -> Stream f m r
wrap = Step

effect :: forall m f r. Monad m => Functor f => m (Stream f m r) -> Stream f m r
effect = Effect

yields :: forall m f r. Monad m => Functor f => f r -> Stream f m r
yields fr = Step (map Return fr)

zipsWith :: forall f g h m r. Monad m => Functor h => (forall x y . f x -> g y -> h (Tuple x y)) -> Stream f m r -> Stream g m r -> Stream h m r
zipsWith phi = zipsWith'(\xyp fx gy -> (\(Tuple x y) -> xyp x y) <$> phi fx gy)

zips :: forall m f g r. Monad m => Functor f => Functor g => Stream f m r -> Stream g m r -> Stream (Compose f g) m r
zips = zipsWith'(\p fx gy -> Compose (map (\x -> map (\y -> p x y) gy) fx))

interleaves :: forall m h r. Monad m => Applicative h => Stream h m r -> Stream h m r -> Stream h m r
interleaves = zipsWith' lift2

switch :: forall f g r. Coproduct f g r -> Coproduct g f r
switch s = N.wrap $ case (N.unwrap s) of 
  Left a -> Right a
  Right a -> Left a

separate :: forall m f g r. Monad m => Functor f => Functor g => Stream (Coproduct f g) m r -> Stream f (Stream g m) r
separate str = destroyExposed
  str
  (\x -> case (N.unwrap x) of 
    Left fss -> wrap fss
    Right gss -> effect (yields gss))
  (effect <<< lift)
  pure

unseparate :: forall m f g r. Monad m => Functor f => Functor g => Stream f (Stream g m) r -> Stream (Coproduct f g) m r
unseparate str = destroyExposed
  str
  (wrap <<< N.wrap <<< Left)
  (join <<< maps (N.wrap <<< Right))
  pure

expand :: forall m f g h r. Monad m => Functor f => (forall a b. (g a -> b) -> f a -> h b) -> Stream f m r -> Stream g (Stream h m) r
expand ext = loop where
  loop (Return r) = Return r
  loop (Step f) = Effect $ Step $ ext (Return <<< Step) (map loop f)
  loop (Effect m) = Effect $ Effect $ map (Return <<< loop) m

expandPost :: forall m g f g h r. Monad m => Functor g => (forall a b. (g a -> b) -> f a -> h b) -> Stream f m r -> Stream g (Stream h m) r
expandPost ext = loop where
  loop (Return r) = Return r
  loop (Step f) = Effect $ Step $ ext (Return <<< Step <<< map loop) f
  loop (Effect m) = Effect $ Effect $ map (Return <<< loop) m

unzips :: forall m f g r. Monad m => Functor f => Functor g => Stream (Compose f g) m r ->  Stream f (Stream g m) r
unzips str = destroyExposed
  str
  (\(Compose fgstr) -> Step (map (Effect <<< yields) fgstr))
  (Effect <<< lift)
  pure

groups :: forall m f g r. Monad m => Functor f => Functor g => Stream (Coproduct f g) m r -> Stream (Coproduct (Stream f m) (Stream g m)) m r
groups = loop
  where
  loop str = do
    e <- lift $ inspect str
    case e of
      Left r -> pure r
      Right ostr -> case (N.unwrap ostr) of
        Right gstr -> wrap $ N.wrap $ Right (map loop (cleanR (wrap (N.wrap $ Right gstr))))
        Left fstr -> wrap $ N.wrap $ Left (map loop (cleanL (wrap (N.wrap $ Left fstr))))

  -- cleanL :: forall m f g r. Monad m => Functor f => Functor g => Stream (Coproduct f g) m r -> Stream f m (Stream (Coproduct f g) m r)
  cleanL = go where
    go s = do
     e <- lift $ inspect s
     case e of
      Left r           -> pure (pure r)
      Right (Coproduct (Left fstr)) -> wrap (map go fstr)
      Right (Coproduct (Right gstr)) -> pure (wrap (N.wrap $ Right gstr))

  -- cleanR :: forall m f g r. Monad m => Functor f => Functor g => Stream (Coproduct f g) m r -> Stream g m (Stream (Coproduct f g) m r)
  cleanR = go where
    go s = do
     e <- lift $ inspect s
     case e of
      Left r           -> pure (pure r)
      Right (Coproduct (Left fstr)) -> pure (wrap (N.wrap $ Left fstr))
      Right (Coproduct (Right gstr)) -> wrap (map go gstr)

never :: forall f m r. Monad m => Applicative f => Stream f m r
never = let loop = defer \_ -> Step $ pure (Effect (pure $ force loop)) in force loop

untilJust :: forall m f r. Monad m => Applicative f => m (Maybe r) -> Stream f m r
untilJust act = loop where
  loop = Effect $ do
    m <- act
    case m of
      Nothing -> pure $ Step $ pure loop
      Just a -> pure $ Return a

cutoff :: forall m f r. Monad m => Functor f => Int -> Stream f m r -> Stream f m (Maybe r)
cutoff = loop where
  loop 0 _ = pure Nothing
  loop n str = do
      e <- lift $ inspect str
      case e of
        Left r -> pure (Just r)
        Right (frest) -> Step $ map (loop (n-1)) frest




