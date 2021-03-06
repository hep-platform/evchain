module Test.EventChain.Common where

import Control.Monad.Error

-- | 

guardMsg :: (Monad m) => String -> m Bool ->  ErrorT String m () 
guardMsg msg act = do b <- lift act
                      if b then return () else throwError msg 


-- | 

trueOrFalse :: Either String a -> Bool 
trueOrFalse e = either (const False) (const True) e