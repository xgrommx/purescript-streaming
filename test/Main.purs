module Test.Main where

import Data.Array (reverse, (..))
import Prelude (Unit, bind, discard, id, map, pure, show, unit, (#), ($), (*), (*>), (+), (<<<), (<>), (>), (>=))

import Control.Apply (lift2, lift3)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Console (CONSOLE, logShow)
import Control.Monad.Eff.Ref (modifyRef, newRef, readRef)
import Control.Monad.Eff.Unsafe (unsafeCoerceEff)
import Control.Monad.IO (launchIO)
import Control.Monad.IOSync (runIOSync)
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Functor.Of ((:>))
import Data.Int (even, odd)
import Data.List.Lazy as LL
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Tuple (Tuple(..))
import Foldl as L
import Streaming.Internal (chunksOf, concats, maps, separate) as S
import Streaming.Prelude (Tuple3(..))
import Streaming.Prelude (breakWhen, chain, concat, copy, distinguish, drained, each, effects, filter, fold, fold_, group, groupBy, length, map', mapM, mapM_, mapped, printEff, printIO, printIOSync, product, repeat, scan, slidingWindow, splitAt, store, sum, take, toList, toList_, unzip, yield) as S

main :: forall e. Eff (console :: CONSOLE | e) Unit
main = do
  a <- S.toList_ $ S.yield 1 *> S.yield 2
  logShow a
  v <- S.fold_ (+) 0 id $ S.each (1..1000)
  logShow v
  -- mapM_ logShow $ each (1 .. 3)
  _ <-  unsafeCoerceEff $ runIOSync $ launchIO $ S.printIO $ S.each (1..3)
  _ <- S.mapM_ logShow $ S.map' reverse $ S.each [[1,2,3], [4,5,6]]
  unsafeCoerceEff $ runIOSync $ launchIO $ S.printIO $ S.take 1 $ S.repeat 1
  (n :> rest) <- S.sum $ S.splitAt 3 $ S.each (1..10)
  -- logShow n
  -- unsafeCoerceEff $ runIOSync $ launchIO $ print (force rest)
  v' <- S.fold_ (+) 0 id $ LL.replicateM 1 (S.yield 10)
  logShow v'
  rest <- S.effects $ S.splitAt 2 $ S.each (1..5)
  S.mapM_ logShow rest
  r <- unsafeCoerceEff $ runIOSync $ S.printIOSync $ S.store S.product $ S.each (1..4)
  logShow r
  r' <- S.product $ S.chain logShow $ S.each (1..5)
  logShow r'
  unsafeCoerceEff $ runIOSync $ S.printIOSync $ S.concat (S.each [[1,2], [3]])
  logShow "---"
  unsafeCoerceEff $ runIOSync $ S.printIOSync $ S.concat $ S.each [Just 1, Nothing, Just 2]
  logShow "---"
  unsafeCoerceEff $ runIOSync $ S.printIOSync $ S.concat $ S.each [Right 1, Left "Error!", Right 2]
  logShow "---"
  unsafeCoerceEff $ runIOSync $ S.printIOSync $ S.concat $ S.each [Tuple 'A' 1, Tuple 'B' 2]
  logShow "---"
  unsafeCoerceEff $ runIOSync $ S.printIOSync $ S.scan (<>) "" id $ S.each (["a", "b", "c", "d"])
  unsafeCoerceEff $ runIOSync $ S.printIOSync $ S.slidingWindow 4 $ S.each [1, 2, 3, 4, 5, 6]
  l <- S.toList $ S.mapped S.toList $ S.group $ S.each (String.split (String.Pattern "") "baaaaad")
  logShow l
  l' <- S.toList $ S.concats $ S.maps (S.drained <<< S.splitAt 1) $ S.group $ S.each (String.split (String.Pattern "") "baaaaaaad")
  logShow l'
  unsafeCoerceEff $ runIOSync $ S.printIOSync $ S.mapped S.toList $ S.groupBy (>=) $ S.each [1,2,3,1,2,3,4,3,2,4,5,6,7,6,5]
  -- l1 <- toList $ print' $ separate $ maps switch $ maps (distinguish (_=="a")) $ each (S.split (S.Pattern "") "banana")
  l1 <- S.toList $ S.toList $ S.separate (S.maps (S.distinguish even) $ S.each (1..10))
  logShow l1
  l2 <- unsafeCoerceEff $ runIOSync $ S.printIOSync $ S.mapped S.length $ S.chunksOf 3 $ S.each (1..10)
  logShow l2
  l3 <- (S.toList <<< S.mapped S.toList <<< S.chunksOf 5) $ (S.toList <<< S.mapped S.toList <<< S.chunksOf 3) $ S.copy $ S.each (1..10)
  logShow l3
  l4 <- (S.toList <<< S.mapped S.toList <<< S.chunksOf 4) $ (S.toList <<< S.mapped S.toList <<< S.chunksOf 3) $ S.copy $ (S.toList <<< S.mapped S.toList <<< S.chunksOf 2) $ S.copy $ S.each (1..12)
  logShow l4
  let xs =  map (\x -> Tuple x (show x)) (1..5::Int)
  l5 <- S.toList $ S.toList $ S.unzip (S.each xs)
  logShow l5

  v1 <- S.fold (+) 0 id $ S.each (1..1000)
  logShow v1

  S.printEff $ S.mapped S.toList $ S.groupBy (>=) $ S.each [1,2,3,1,2,3,4,3,2,4,5,6,7,6,5]

  x <- L.purely S.fold (lift2 Tuple L.sum L.product) $ S.each (1..10)
  logShow x

  x' <- L.purely S.fold (lift2 Tuple (L.handles (L.filtered odd) L.sum) (L.handles (L.filtered even) L.product)) $ S.each (1..10)
  logShow x'

  S.printEff $ traverse_ S.yield (1..10)

  xx <- S.sum $ S.product <<< S.copy $ S.each (1..10)
  logShow xx
  
  xxx <- S.sum $ S.filter odd $ S.product $ S.filter even $ S.copy $ S.each (1..10)

  logShow xxx

  xxxx <- S.sum $ S.filter odd $ S.store (S.product <<< S.filter even) $ S.each (1..10)

  logShow xxxx

  -- _ <- L.impurely foldM (lift3 (\a b c -> Tuple b c) (L.sink print) (L.generalize L.sum) (L.generalize L.product)) $ each (1..4)
  xxxxx <- S.sum $ S.store (S.sum <<< S.mapped S.product <<< S.chunksOf 2) $ S.store (S.product <<< S.mapped S.sum <<< S.chunksOf 2 ) $ S.each (1..6)
  logShow xxxxx

  S.printEff $ L.purely S.scan L.list $ S.each (3..5)

  rest <- S.each (1..10) # L.purely S.breakWhen L.sum (_>10) # S.printEff
  logShow "-------"
  S.printEff rest
  
  logShow "-------"
  i <- L.purely S.fold_ L.sum $ S.each (1..10)
  logShow i

  logShow "-------"
  i2 <- L.purely S.fold_ (lift3 Tuple3 L.sum L.product L.list) $ S.each (1..10)
  logShow i2

  S.printEff $ S.mapped (L.purely S.fold (lift3 Tuple3 L.sum L.product L.list)) $ S.chunksOf 3 (S.each (1..10))

  unsafeCoerceEff $ S.printEff $ S.mapM readRef $ S.chain (\ior -> modifyRef ior (_*100)) $ S.mapM newRef $ S.each (1..6)

  pure unit
