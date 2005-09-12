----------------------------------------------------------------------
-- |
-- Module      : FiniteState
-- Maintainer  : BB
-- Stability   : (stable)
-- Portability : (portable)
--
-- > CVS $Date: 2005/09/12 15:46:44 $ 
-- > CVS $Author: bringert $
-- > CVS $Revision: 1.3 $
--
-- A simple finite state network module.
-----------------------------------------------------------------------------
module GF.Speech.FiniteState (FA, State,
			      startState, finalStates,
			      states, transitions,
			      newFA, addFinalState,
			      newState, newTransition, newTransitions,
			      moveLabelsToNodes, minimize, asGraph) where

import Data.Graph.Inductive
import Data.List (nub,partition)
import Data.Maybe (fromJust)

import Debug.Trace

data FA a b = FA (Gr a b) Node [Node]

type State = Node

startState :: FA a b -> State
startState (FA _ s _) = s

finalStates :: FA a b -> [State]
finalStates (FA _ _ ss) = ss

states :: FA a b -> [(State,a)]
states (FA g _ _) = labNodes g

transitions :: FA a b -> [(State,State,b)]
transitions (FA g _ _) = labEdges g

newFA :: a -- ^ Start node label
      -> FA a b
newFA l = FA g' s []
    where g = empty
	  s = freshNode g
	  g' = insNode (s,l) g

addFinalState :: Node -> FA a b -> FA a b
addFinalState f (FA g s ss) = FA g s (f:ss)

newState :: a -> FA a b -> (FA a b, State)
newState x (FA g s ss) = (FA g' s ss, n)
    where (g',n) = addNode x g

newTransition :: Node -> Node -> b -> FA a b -> FA a b
newTransition f t l = onGraph (insEdge (f,t,l))

newTransitions :: [(Node,Node,b)] -> FA a b -> FA a b
newTransitions ts = onGraph (insEdges ts)

mapStates :: (a -> c) -> FA a b -> FA c b
mapStates f (FA g s ss) = FA (nmap f g) s ss

asGraph :: FA a b -> Gr a b
asGraph (FA g _ _) = g

minimize :: FA () (Maybe a) -> FA () (Maybe a)
minimize = onGraph mimimizeGr1

--
-- * Graph functions
--

onGraph :: (Gr a b -> Gr c d) -> FA a b -> FA c d
onGraph f (FA g s ss) = FA (f g) s ss

addNode :: DynGraph gr => a -> gr a b -> (gr a b, Node)
addNode x g = let s = freshNode g in (insNode (s,x) g, s)

freshNode :: Graph gr => gr a b -> Node
freshNode = succ . snd . nodeRange 

-- | Get an infinte supply of new nodes.
freshNodes :: Graph gr => gr a b -> [Node]
freshNodes g = [snd (nodeRange g)+1..]

-- | Transform a standard finite automaton with labelled edges
--   to one where the labels are on the nodes instead. This can add
--   up to one extra node per edge.
moveLabelsToNodes :: Eq a => FA () (Maybe a) -> FA (Maybe a) ()
moveLabelsToNodes = onGraph moveLabelsToNodes_

moveLabelsToNodes_ :: (DynGraph gr, Eq a) => gr () (Maybe a) -> gr (Maybe a) ()
moveLabelsToNodes_ g = gmap f g'
    where g' = sameLabelIncoming g
          f (to,n,(),fr) = (removeAdjLabels to, n, l, removeAdjLabels fr)
	      where l | not (allEqual ls)
			   = error $ "moveLabelsToNodes: not all incoming labels are equal"
		      | null ls = Nothing
		      | otherwise = head ls
		    ls = map snd $ lpre g' n
	  removeAdjLabels = map (\ (_,n) -> ((),n))

-- | Add the extra nodes needed to make sure that all edges to a node
--   have the same label.
sameLabelIncoming :: (DynGraph gr, Eq b) => gr () (Maybe b) -> gr () (Maybe b)
sameLabelIncoming gr = foldr fixIncoming gr (nodes gr)

fixIncoming :: (DynGraph gr, Eq b) => Node -> gr () (Maybe b) -> gr () (Maybe b)
fixIncoming n gr | allLabelsEqual to' = gr
		 | otherwise = addContexts newContexts $ delNode n gr
    where (to,_,_,fr) = context gr n
	  -- move cyclic edges to the list of incoming edges
	  (cyc,fr') = partition (\ (_,t) -> t == n) fr
	  to' = to ++ cyc
	  -- make new nodes for each unique label
	  newNodes = zip (nub $ map fst to') (freshNodes gr) 
	  -- for each cyclic edge, add an edge to the node for 
	  -- that label (could be the current node).
	  fr'' = fr' ++ [ (l',fromJust (lookup l' newNodes)) | (l',f) <- to', f == n ]
	  -- keep all incoming non-cyclic edges with the right label.
	  to'' l = [ e | e@(l',f) <- to', l'==l, f /= n ]
	  newContexts = [ (to'' l,n',(),fr'') | (l,n') <- newNodes]

allLabelsEqual :: Eq b => Adj b -> Bool
allLabelsEqual = allEqual . map fst

edgeLabel :: LEdge b -> b
edgeLabel (_,_,l) = l

ledgeToEdge ::  LEdge b -> Edge
ledgeToEdge (f,t,_) = (f,t)

addContexts :: DynGraph gr => [Context a b] -> gr a b -> gr a b
addContexts cs gr = foldr (&) gr cs

mimimizeGr1 :: DynGraph gr => gr () (Maybe a) -> gr () (Maybe a)
mimimizeGr1 = removeEmptyLoops 

removeEmptyLoops :: DynGraph gr => gr () (Maybe a) -> gr () (Maybe a)
removeEmptyLoops = gmap (\ (i,n,(),o) -> (filter (r n) i,n,(),filter (r n) o))
  where r n (Nothing,n') | n' == n = False
	r _ _ = True

mimimizeGr2 :: DynGraph gr => gr (Maybe a) () -> gr (Maybe a) ()
mimimizeGr2 gr = gr 

--
-- * Utilities
--

allEqual :: Eq a => [a] -> Bool
allEqual [] = True
allEqual (x:xs) = all (==x) xs

