{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns    #-}

module Thentos.Transaction.TH
    ( makeThentosAcidicPhase1
    , makeThentosAcidicPhase2
    )
where

import Control.Applicative ((<$>))
import Control.Monad (replicateM)
import Data.Acid (Update, Query, makeAcidic)
import Language.Haskell.TH
import Text.Show.Pretty (ppShow)

import Thentos.Transaction.Core (ThentosUpdate, ThentosQuery)
import Thentos.Types (DB, ThentosError)

data ThentosTransactionType = ThentosQ | ThentosU

makeThentosAcidicPhase1 :: [Name] -> Q [Dec]
makeThentosAcidicPhase1 names = concat <$> mapM processTransaction names

makeThentosAcidicPhase2 :: Name -> [Name] -> Q [Dec]
makeThentosAcidicPhase2 stateName eventNames =
    makeAcidic stateName $ map dropPrefix eventNames

processTransaction :: Name -> Q [Dec]
processTransaction functionName = do
    info <- reify functionName
    let typ = case info of
            VarI _ t _ _ -> t
            _ -> error $ nameBase functionName ++ " is not a function"
    processTransaction' functionName typ

processTransaction' :: Name -> Type -> Q [Dec]
processTransaction' functionName typ = do
    let name_suffix = dropPrefix functionName
        (sig, transType) = makeThentosType typ
        signature = SigD name_suffix sig
    fun <- makeFinalFun functionName name_suffix (countArgs typ) transType
    return [signature, fun]

dropPrefix :: Name -> Name
dropPrefix (nameBase -> s)
    | take 6 s == "trans_" = mkName $ drop 6 s
    | otherwise            = error $ "expected function name starting with 'trans_', got '" ++ s ++ "'"

-- | Count the number of arguments in a function type
countArgs :: Type -> Int
countArgs (ForallT _ _ app) = countArgs app
countArgs (AppT (AppT ArrowT _arg) returnType) = 1 + countArgs returnType
countArgs _ = 0

-- | Convert e.g. @a -> b -> ThentosUpdate Foo@ to
-- @a -> b -> Update DB (Either ThentosError Foo)@ and check whether it
-- is an Update or a Query.
makeThentosType :: Type -> (Type, ThentosTransactionType)
makeThentosType (AppT (AppT ArrowT arg) returnType) =
    let (rightOfArrow, transType) = makeThentosType returnType
    in (AppT (AppT ArrowT arg) rightOfArrow, transType)
makeThentosType (AppT (AppT t (VarT _)) returnType)
    | t == ConT (''ThentosUpdate) = (updateType, ThentosU)
    | t == ConT (''ThentosQuery) = (queryType, ThentosQ)
    | otherwise = error $ "not a thentos transaction type:" ++ ppprint t
  where
    updateType :: Type
    updateType = makeAcidStateType ''Update

    queryType :: Type
    queryType = makeAcidStateType ''Query

    makeAcidStateType :: Name -> Type
    makeAcidStateType acidStateTypeConstructor =
        AppT (AppT (ConT acidStateTypeConstructor) (ConT ''DB)) (AppT (AppT (ConT ''Either) (ConT ''ThentosError)) returnType)
makeThentosType (ForallT _ _ app) = makeThentosType app
makeThentosType t = error $ "not a thentos transaction type: " ++ ppprint t

-- | Generate a function definition.
makeFinalFun :: Name -> Name -> Int -> ThentosTransactionType -> Q Dec
makeFinalFun nameWithPrefix functionName argCount transType = do
    args <- replicateM argCount (newName "arg")
    let funToApply =
            case transType of
                ThentosU -> "runThentosUpdate"
                ThentosQ -> "runThentosQuery"
        body = NormalB $ makeFunApp (mkName funToApply) nameWithPrefix args
    return $ FunD functionName [Clause (map VarP args) body []]

-- | Generate a function application expression like
-- @runThentosQuery (trans_do_something x y)@.
makeFunApp :: Name -> Name -> [Name] -> Exp
makeFunApp updateOrQuery funName argNames =
    AppE (VarE updateOrQuery) $ foldl AppE (VarE funName) (map VarE argNames)

ppprint :: (Ppr a, Show a) => a -> [Char]
ppprint t = "\n\n" ++ pprint t ++ "\n\n" ++ ppShow t ++ "\n"
