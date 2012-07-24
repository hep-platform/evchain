{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      : HEP.Automation.MadGraph.EventChain.LHEConn
-- Copyright   : (c) 2012 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-- Connecting multiple LHE files 
--
-----------------------------------------------------------------------------

module HEP.Automation.MadGraph.EventChain.LHEConn where 
-- other package of others
import           Control.Applicative ((<$>),(<*>))
import           Control.Monad.State hiding (mapM)
import           Data.Either
import           Data.Foldable (foldr,foldrM)
import           Data.Function (on)
import qualified Data.IntMap as IM
import           Data.List (intercalate, sortBy)
import qualified Data.Map as M
import           Data.Traversable 
import           Data.Vector.Storable ((!))
import qualified Numeric.LinearAlgebra as NL
import           System.IO
-- other package of mine
import           HEP.Parser.LHEParser.Type
import           HEP.Util.Functions
-- this package
import           HEP.Automation.MadGraph.EventChain.Print
import           HEP.Automation.MadGraph.EventChain.Type 
import           HEP.Automation.MadGraph.EventChain.Util
-- prelude
import           Prelude hiding (mapM,foldr)

-- | 

type Status = Int







-- | 

matchPtl4Decay :: (DNode (ParticleID,PKind) ProcessID, [DecayID])
               -> LHEvent
               -> Either String MatchedLHEvent
matchPtl4Decay (inc,out) lhe = matchInOut procid (incids,outids) lhe 
  where procid :: ProcessID
        incids :: [(ParticleID,SelectFunc)]
        (procid,incids) = case inc of DNode (x,y) p -> (p,[(x,mkSelFunc In y)])
        outids = map (getSelPair Out) out 

-- | 

matchFullDecay :: IM.IntMap LHEvent -- ^ event repository 
               -> ContextEvent      -- ^ current context for mother
               -> DecayID
               -> Either String DecayFull
matchFullDecay m ctxt (GTerminal (TNode (ptl_id,pkind))) = 
    case pkind of 
      KPDGID pdg_id -> return (GTerminal (TNode (ptl_id,pdg_id)))
      _ -> return (GTerminal (TNode (ptl_id,0)))   -- this is very bad but I do not have any solution.
matchFullDecay m ctxt (GDecay elem@(DNode (ptl_id,pkind) proc_id, ds)) = 
    case pkind of 
      KPDGID pdg_id -> case IM.lookup proc_id m of 
                         Nothing -> Left $ show proc_id ++ " process doesn't exist"
                         Just lhe -> do 
                           mev <- matchPtl4Decay elem lhe
                           let ptrip = findPTripletUsingPtlIDFrmOutPtls ptl_id momev 
                               lxfrm = relLrntzXfrm ptrip momev
                               momprocid = (mlhev_procid.selfEvent) ctxt 
                           let dctxt = CEvent (olxfrm NL.<> lxfrm) (Just (momprocid,ptrip)) mev 
                           mds <- mapM (matchFullDecay m dctxt) ds
                           return (GDecay (DNode (ptl_id,pdg_id) dctxt, mds)) 
  where momev = selfEvent ctxt
        olxfrm = absoluteContext ctxt

-- | 

matchFullCross :: IM.IntMap LHEvent  -- ^ event repository 
               -> CrossID 
               -> Either String CrossFull
matchFullCross m g@(GCross (XNode pid) inc out) =
    case IM.lookup pid m of 
      Nothing -> Left $ show pid ++ " process doesn't exist"
      Just lhe -> do 
        (mev :: MatchedLHEvent) <- matchPtl4Cross g lhe
        let xcontext = CEvent (NL.ident 4) Nothing mev  
        (mis :: [DecayFull]) <- mapM (matchFullDecay m xcontext) inc
        (mos :: [DecayFull]) <- mapM (matchFullDecay m xcontext) out 
        return (GCross (XNode xcontext) mis mos)



-- | 

adjustPtlInfosInMLHEvent :: (PtlInfo -> PtlInfo, (ParticleID,PtlInfo) -> PtlInfo) 
                         -> MatchedLHEvent 
                         -> ParticleCoordMap 
                         -> ([PtlInfo],[PtlInfo],[PtlInfo],ParticleCoordMap)
adjustPtlInfosInMLHEvent (f,g) mev mm = (map snd inc,map snd out,int,mm'')
  where procid = mlhev_procid mev
        inc = map ((,) <$> fst <*> (f.g)) (mlhev_incoming mev)
        out = map ((,) <$> fst <*> (f.g)) (mlhev_outgoing mev)
        int = map f (mlhev_intermediate mev)
        insfunc x m = M.insert (procid,fst x) ((ptlid.snd) x) m
        mm' = foldr insfunc mm inc
        mm'' = foldr insfunc mm' out


-- | 

accumTotalEvent :: CrossFull -> IO [PtlInfo]
accumTotalEvent g = do (_,_,result,_) <- execStateT (traverse action g) 
                                                    (0,0, IM.empty :: IM.IntMap PtlInfo
                                                        , M.empty :: ParticleCoordMap ) 
                       let result' = IM.elems result
                       let sortedResult = sortBy (compare `on` ptlid) result'
                       return sortedResult 
  where action cev = do 
          let (lrot,mmom,mev) = (absoluteContext cev, relativeContext cev, selfEvent cev)
              pinfos = (getPInfos . mlhev_orig) mev
              ptlids = map ptlid pinfos
              icols = filter (/= 0) (concatMap ((\x -> [fst x, snd x]) . icolup )
                                               pinfos)
              maxid = maximum ptlids 
              maxicol = maximum icols
              minicol = minimum icols 
          (stid,stcol,rmap,stmm) <- get
          let mopinfo = fmap (pt_pinfo.snd) mmom 
              rpinfo = (snd . head . mlhev_incoming ) mev
              (coloffset,colfunc) = colChangePair stcol (mopinfo,rpinfo) 
          let idfunc = adjustIds (idChange stid) colfunc


          let (momf,rmap1) = 
                  flipMaybe mmom (id,rmap) 
                      (\(procid,PTriplet pid pcode opinfo) -> 
                          let oid = idChange stid (ptlid rpinfo)
                              nid = maybe (error ("herehere\n" ++ show (procid,pid) ++ "\n" ++ show stmm)) id (M.lookup (procid,pid) stmm)
                              rmap1 = IM.adjust unstabilize nid rmap
                              midadj = motherAdjustID (oid,nid) 
                          in (adjustMom lrot . adjustSpin (opinfo,rpinfo) . midadj , rmap1) )


          let (ri,ro,rm,stmm') = adjustPtlInfosInMLHEvent (momf.idfunc,snd) mev stmm
              kri = map ((,) <$> ptlid <*> id) ri
              kro = map ((,) <$> ptlid <*> id) ro
              krm = map ((,) <$> ptlid <*> id) rm 
              rmap2 = maybe (insertAll kri rmap1) (const rmap1) mmom 
              rmap3 = insertAll kro rmap2
              rmap4 = insertAll krm rmap3 
          put (stid+maxid-1,stcol+maxicol-minicol+1-coloffset,rmap4,stmm')



-- | 

motherAdjustID :: (PtlID,PtlID) -> PtlInfo -> PtlInfo
motherAdjustID (oid,nid) = idAdj (\y -> if y == oid then nid else y)


-- | 

extractIDsFromMLHE :: MatchedLHEvent -> ([(ParticleID,PtlID)],[(ParticleID,PtlID)])
extractIDsFromMLHE mlhe = 
  ( map (\x->(fst x, ptlid (snd x))) (mlhev_incoming mlhe)
  , map (\x->(fst x, ptlid (snd x))) (mlhev_outgoing mlhe) )


      

