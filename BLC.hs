-- This works as a ghc plugin:
-- # ghc -dynamic -c BLC.hs -package ghc
-- # ghc -package ghc -dynamic -c -fplugin=BLC Sample.hs

{-# LANGUAGE BangPatterns #-}

module BLC (plugin) where

import GhcPlugins
import TyCon
import DataCon
import FastString (fsLit)
import Name (mkSystemVarName)
import Unique
import Data.List
import qualified Data.Map as M

plugin :: Plugin
plugin = defaultPlugin{ installCoreToDos = install }

install :: [CommandLineOption] -> [CoreToDo] -> CoreM [CoreToDo]
install _ todo = do
    reinitializeGlobals
    return (todo ++ [CoreDoPluginPass "generate blc" pass])

pass :: ModGuts -> CoreM ModGuts
pass mg = do
    -- putMsg $ ppr (mg_tcs mg)
    let !types = summarize (mg_tcs mg)
    putMsg $ ppr (mg_binds mg)
    case filter (("main" ==) . getOccString) $ mg_binds mg >>= \b -> case b of NonRec b _ -> [b]; Rec bs -> map fst bs of
        [m] -> do
            let code = codeGen types (getName m) (mg_binds mg)
            liftIO $ putStrLn (pr 0 code)
            liftIO $ putStrLn (blc code)
            liftIO $ putStrLn "Ok."
        _ -> liftIO $ putStrLn "Oops, not exactly one main function."
    return mg

data MyCon = MyCon{ conI :: !Int, conW :: !Int, conA :: !Int, conNs :: [String] }
type MyTypes = M.Map String MyCon

summarize :: [TyCon] -> MyTypes
summarize = M.fromList . (>>= go) where
    go tc
        | isAlgTyCon tc = do
            let cs = reverse (visibleDataCons (algTyConRhs tc))
                ns = map getOccString cs
            (c, i) <- zip cs [0..]
            return (getOccString c, MyCon{ conI = i, conW = length cs, conA = dataConSourceArity c, conNs = ns })
        | otherwise = []

data MyExpr = MyLam MyExpr | MyApp MyExpr MyExpr | MyVar Int
    deriving Show

infixl <^>

(<^>) = MyApp

noName = mkSystemVarName (mkUnique 'x' 0) (fsLit "<noName>")

codeGen :: MyTypes -> Name -> CoreProgram -> MyExpr
codeGen types main bs = go bs [] where
    go [] vs = case findIndex ((main ==) . getName) vs of
        Just n -> MyVar n
        Nothing -> error "BLC: no main function"
    go (b : bs) vs = mkLet types b (go bs) vs

expr :: MyTypes -> Expr CoreBndr -> [Name] -> MyExpr
expr types (Var n) vs
    | isValName (varName n) = case findIndex (== getName n) vs of
        Just n -> MyVar n
        _ -> case M.lookup (getOccString n) types of
            Just ci ->
                iterate MyLam (
                    foldr (\i e -> e <^> MyVar i) (MyVar (conI ci))
                    [conW ci..conW ci + conA ci - 1]
                ) !! (conW ci + conA ci)
            _ -> error $ "BLC: free variable <" ++ getOccString n ++ "> " ++ show (map getOccString vs)
    | otherwise = error "BLC: non-value variable"
expr types (Lit _) vs = error "BLC: literals not supported"
expr types (App a b) vs = case b of
    Type{} -> expr types a vs
    Coercion{} -> expr types a vs
    _ -> expr types a vs <^> expr types b vs
expr types (Lam v e) vs
    | isId v = MyLam (expr types e (getName v : vs))
    | otherwise = expr types e vs
expr types (Let b e) vs = mkLet types b (expr types e) vs
expr types (Case e b _ alts) vs = mkCase types e b alts vs
expr types (Cast e _) vs = expr types e vs
expr types (Tick _ e) vs = expr types e vs
expr types (Type _) vs = error "BLC: unexpected 'Type' expression"
expr types (Coercion _) vs = error "BLC: unexpected 'Coercion' expression"

mkLet types (NonRec v e) e' vs = MyLam (e' (getName v : vs)) <^> expr types e vs
-- mkLet types (Rec [(b,e)]) e' vs = error "TODO: implement special case"
mkLet types (Rec g) e' vs =
    MyLam (MyVar 0 <^> MyVar 0) <^>
    MyLam (
        foldr (\x y -> y <^> (MyVar 0 <^> MyVar 0 <^> (foldr (const MyLam) (MyVar x) g)))
            (foldr (const MyLam) (MyLam (
                foldr (\b i -> i <^> expr types (snd b) ([noName] ++ map (getName . fst) g ++ [noName] ++ vs)) (MyVar 0) g)) g) [0..length g-1]) <^>
    (foldr (const MyLam) (e' (map (getName . fst) g ++ vs)) g)

mkCase types e b alts vs = mkLet types (NonRec b e) (mkCase' types alts) vs

mkCase' types ((DEFAULT, _, e) : []) vs = expr types e vs
mkCase' types ((DEFAULT, _, e) : alts) vs = undefined
mkCase' types [] vs = MyVar 0
mkCase' types alts@((DataAlt n,_,_):_) vs =
    foldr (\n i -> i <^> mkAlt n) (MyVar 0) ns
  where
    ns = conNs (types M.! getOccString n)
    mkAlt n = foldr (const MyLam) (expr types e (map getName (reverse bs) ++ vs)) bs where
       [(bs,e)] = [(bs,e) | (DataAlt n',bs,e) <- alts, n == getOccString n']
       ci = types M.! n

pr :: Int -> MyExpr -> String
pr _ (MyVar n) = show n
pr b (MyApp n m) = (if b > 1 then ("(" ++) . (++ ")") else id) $ pr 1 n ++ " " ++ pr 2 m
pr b (MyLam n) =  (if b > 0 then ("(" ++) . (++ ")") else id) $ "\\" ++ pr 0 n

blc :: MyExpr -> String
blc (MyVar n) = replicate (n+1) '1' ++ "0"
blc (MyApp n m) = "01" ++ blc n ++ blc m
blc (MyLam n) = "00" ++ blc n

