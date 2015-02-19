{-# LANGUAGE DeriveFunctor,TupleSections,TypeOperators,MultiParamTypeClasses, FlexibleInstances,TypeSynonymInstances, LambdaCase, ExistentialQuantification, Rank2Types, GeneralizedNewtypeDeriving #-}
module Impl.TimeEnv(Behavior, Event, Now, never, curNow, whenJust, switch, async, runFRP, unsafeSyncIO) where

import Control.Monad.Writer hiding (mapM_)
import Control.Monad.Writer.Class
import Control.Monad.Reader.Class
import Control.Monad.Reader hiding (mapM_)
import Control.Monad hiding (mapM_)
import Control.Monad.IO.Class  hiding (mapM_)
import Control.Applicative hiding (empty)
import Control.Concurrent
import Data.IORef
import Data.Sequence hiding (length)
import Data.Foldable
import Data.Maybe
import System.IO.Unsafe -- only for unsafeMemoAgain at the bottom
import Debug.Trace

import Prelude hiding (mapM_)

import Swap
import Impl.Ref
import Impl.EventBehavior
import Impl.UnscopedTIVar
import Impl.ConcFlag

-- Hide implementation details with newtypes

type Event    = E RealTimeEnv  
type Behavior = B RealTimeEnv  


data APlan = forall a. APlan (Ref (Event a))
type Plans = Seq APlan



newtype RealTimeEnv a = TE ( ReaderT (Flag,Clock,Round) (WriterT Plans IO) a)
 deriving (Monad,Applicative,Functor,MonadWriter Plans ,MonadReader (Flag,Clock,Round), MonadIO)


-- Plan stuff

instance TimeEnv RealTimeEnv where
 planM = planRef makeWeakRef 
 again = unsafeMemoAgain

planRef makeRef e   = runEvent e >>= \case
  Never -> return Never
  Occ m -> return <$> m
  e'    -> do r <- liftIO $ newIORef (Left e')
              let res = tryAgain r
              ref <- liftIO $ makeRef res
              tell (singleton (APlan ref))
              return res


tryAgain :: IORef (Either (Event (RealTimeEnv a)) a) -> Event a
tryAgain r = E $ 
 do -- liftIO $ putStrLn "Trying" 
    liftIO (readIORef r) >>= \case 
     Right x -> return (Occ x)
     Left e -> runEvent e >>= \case
       Never -> return Never
       Occ m -> do res <- m
                   liftIO $ writeIORef r (Right res)
                   return (Occ res)
       e'    -> do liftIO $ writeIORef r (Left e')
                   return (tryAgain r)



-- Start IO Stuff 

newtype Now a = Now {runNow :: RealTimeEnv a } deriving (Functor,Applicative, Monad)

curNow :: Behavior a -> Now a
curNow b = Now $ fst <$> runB b

async :: IO a -> Now (Event a)
async m = Now $ 
  do (flag,clock,_) <- ask
     ti <- liftIO $ newTIVar clock
     liftIO $ forkIO $ m >>= writeTIVar ti >> signal flag 
     return (tiVarToEv ti)

 
tiVarToEv :: TIVar a -> Event a
tiVarToEv ti = E $ 
  do (_,_,round) <- ask
     case ti `observeAt` round of
      Just a -> return (Occ a)
      Nothing -> return $ tiVarToEv ti

instance Swap Now Event where
 swap e = Now $ planRef makeStrongRef (runNow <$> e) 

                
-- Start main loop
data SomeEvent = forall a. SomeEvent (Event a)

tryPlan :: APlan -> SomeEvent -> RealTimeEnv ()
tryPlan p (SomeEvent e) = runEvent e >>= \case
             Occ  _  -> return ()
             Never   -> return ()
             E _     -> tell (singleton p)


makeStrongRefs :: Plans -> RealTimeEnv [(APlan, SomeEvent)] 
makeStrongRefs pl = catMaybes <$> mapM makeStrongRef (toList pl) where
 makeStrongRef :: APlan -> RealTimeEnv (Maybe (APlan, SomeEvent))
 makeStrongRef (APlan r) = liftIO (deRef r) >>= return . \case
         Just e  -> Just (APlan r, SomeEvent e)
         Nothing -> Nothing

runRound :: Event a -> Plans -> RealTimeEnv (Maybe a)
runRound e pl = 
  do pl' <- makeStrongRefs pl 
     -- liftIO $ putStrLn ("nrplans " ++ show (length pl'))
     mapM_ (uncurry tryPlan) pl'
     runEvent e >>= return . \case
       Occ x -> Just x
       _     -> Nothing

runTimeEnv :: Flag -> Clock -> RealTimeEnv a -> IO (a, Plans)
runTimeEnv f c (TE m) = 
 do r <- curRound c
    runWriterT (runReaderT m (f,c,r))


runFRP :: Now (Event a) -> IO a 
runFRP m = do f <- newFlag 
              c <- newClock             
              (ev,pl) <- runTimeEnv f c (runNow m)
              loop f c ev pl where
  loop f c ev pl = 
     do -- putStrLn "Waiting!!"
        waitForSignal f
        endRound c
        (done, pl') <- runTimeEnv f c (runRound ev pl)  
        case done of
          Just x  -> return x
          Nothing -> loop f c ev pl'
              

-- occasionally handy for debugging

unsafeSyncIO :: IO a -> Now a
unsafeSyncIO m = Now $ liftIO m

-- Memo stuff:

unsafeMemoAgain :: (x -> RealTimeEnv x) -> RealTimeEnv x -> RealTimeEnv x
unsafeMemoAgain again m = unsafePerformIO $ runMemo <$> newIORef (Nothing, m) where
   runMemo mem = 
    do (_,_,r) <- ask
       (v,m) <- liftIO $ readIORef mem 
       res <- case v of
         Just (p,val) -> 
           case compare p r of
            LT -> m
            EQ -> return val
            GT -> error "non monotonic sampling!!"
         Nothing -> m
       liftIO $ writeIORef mem (Just (r,res), again res)
       return res