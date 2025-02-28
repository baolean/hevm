{-# Language DeriveAnyClass #-}
{-# Language DataKinds #-}
{-# Language QuasiQuotes #-}

module EVM.Solidity
  ( solidity
  , solcRuntime
  , solidity'
  , yul'
  , yul
  , yulRuntime
  , JumpType (..)
  , SolcContract (..)
  , StorageItem (..)
  , SourceCache (..)
  , SrcMap (..)
  , CodeType (..)
  , Method (..)
  , SlotType (..)
  , Reference(..)
  , Mutability(..)
  , functionAbi
  , makeSrcMaps
  , readSolc
  , readJSON
  , readStdJSON
  , readCombinedJSON
  , stripBytecodeMetadata
  , stripBytecodeMetadataSym
  , signature
  , solc
  , Language(..)
  , stdjson
  , parseMethodInput
  , lineSubrange
  , astIdMap
  , astSrcMap
  , containsLinkerHole
  , makeSourceCache
) where

import EVM.ABI
import EVM.Types

import Control.Applicative
import Control.Lens hiding (Indexed, (.=))
import Control.Monad
import Data.Aeson hiding (json)
import Data.Aeson.Types
import Data.Aeson.Lens
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Scientific
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as BS16
import Data.ByteString.Lazy (toStrict)
import Data.Char (isDigit)
import Data.Foldable
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.HashMap.Strict qualified as HMap
import Data.List (sort, isPrefixOf, isInfixOf, elemIndex, tails, findIndex)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe
import Data.Semigroup
import Data.Sequence (Seq)
import Data.String.Here qualified as Here
import Data.Text (Text, pack, intercalate)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.Text.IO (readFile, writeFile)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Word (Word8, Word32)
import GHC.Generics (Generic)
import Prelude hiding (readFile, writeFile)
import System.IO hiding (readFile, writeFile)
import System.IO.Temp
import System.Process
import Text.Read (readMaybe)

data StorageItem = StorageItem
  { slotType :: SlotType
  , offset :: Int
  , slot :: Int
  } deriving (Show, Eq)

data SlotType
  -- Note that mapping keys can only be elementary;
  -- that excludes arrays, contracts, and mappings.
  = StorageMapping (NonEmpty AbiType) AbiType
  | StorageValue AbiType
--  | StorageArray AbiType
  deriving Eq

instance Show SlotType where
 show (StorageValue t) = show t
 show (StorageMapping s t) =
   foldr
   (\x y ->
       "mapping("
       <> show x
       <> " => "
       <> y
       <> ")")
   (show t) s

instance Read SlotType where
  readsPrec _ ('m':'a':'p':'p':'i':'n':'g':'(':s) =
    let (lhs,rhs) = case Text.splitOn " => " (pack s) of
          (l:r) -> (l,r)
          _ -> error "could not parse storage item"
        first = fromJust $ parseTypeName mempty lhs
        target = fromJust $ parseTypeName mempty (Text.replace ")" "" (last rhs))
        rest = fmap (fromJust . (parseTypeName mempty . (Text.replace "mapping(" ""))) (take (length rhs - 1) rhs)
    in [(StorageMapping (first NonEmpty.:| rest) target, "")]
  readsPrec _ s = [(StorageValue $ fromMaybe (error "could not parse storage item") (parseTypeName mempty (pack s)),"")]

data SolcContract = SolcContract
  { runtimeCodehash  :: W256
  , creationCodehash :: W256
  , runtimeCode      :: ByteString
  , creationCode     :: ByteString
  , contractName     :: Text
  , constructorInputs :: [(Text, AbiType)]
  , abiMap           :: Map Word32 Method
  , eventMap         :: Map W256 Event
  , errorMap         :: Map W256 SolError
  , immutableReferences :: Map W256 [Reference]
  , storageLayout    :: Maybe (Map Text StorageItem)
  , runtimeSrcmap    :: Seq SrcMap
  , creationSrcmap   :: Seq SrcMap
  } deriving (Show, Eq, Generic)

data Method = Method
  { output :: [(Text, AbiType)]
  , inputs :: [(Text, AbiType)]
  , name :: Text
  , methodSignature :: Text
  , mutability :: Mutability
  } deriving (Show, Eq, Ord, Generic)

data Mutability
  = Pure       -- ^ specified to not read blockchain state
  | View       -- ^ specified to not modify the blockchain state
  | NonPayable -- ^ function does not accept Ether - the default
  | Payable    -- ^ function accepts Ether
 deriving (Show, Eq, Ord, Generic)

data SourceCache = SourceCache
  { files  :: [(Text, ByteString)]
  , lines  :: [(Vector ByteString)]
  , asts   :: Map Text Value
  } deriving (Show, Eq, Generic)

data Reference = Reference
  { start :: Int,
    length :: Int
  } deriving (Show, Eq)

instance FromJSON Reference where
  parseJSON (Object v) = Reference
    <$> v .: "start"
    <*> v .: "length"
  parseJSON invalid =
    typeMismatch "Transaction" invalid

instance Semigroup SourceCache where
  _ <> _ = error "lol"

instance Monoid SourceCache where
  mempty = SourceCache mempty mempty mempty

data JumpType = JumpInto | JumpFrom | JumpRegular
  deriving (Show, Eq, Ord, Generic)

data SrcMap = SM {
  srcMapOffset :: {-# UNPACK #-} !Int,
  srcMapLength :: {-# UNPACK #-} !Int,
  srcMapFile   :: {-# UNPACK #-} !Int,
  srcMapJump   :: JumpType,
  srcMapModifierDepth :: {-# UNPACK #-} !Int
} deriving (Show, Eq, Ord, Generic)

data SrcMapParseState
  = F1 String Int
  | F2 Int String Int
  | F3 Int Int String Int
  | F4 Int Int Int (Maybe JumpType)
  | F5 Int Int Int JumpType String
  | Fe
  deriving Show

data CodeType = Creation | Runtime
  deriving (Show, Eq, Ord)

-- Obscure but efficient parser for the Solidity sourcemap format.
makeSrcMaps :: Text -> Maybe (Seq SrcMap)
makeSrcMaps = (\case (_, Fe, _) -> Nothing; x -> Just (done x))
             . Text.foldl' (flip go) (mempty, F1 [] 1, SM 0 0 0 JumpRegular 0)
  where
    done (xs, s, p) = let (xs', _, _) = go ';' (xs, s, p) in xs'
    readR = read . reverse

    go :: Char -> (Seq SrcMap, SrcMapParseState, SrcMap) -> (Seq SrcMap, SrcMapParseState, SrcMap)
    go ':' (xs, F1 [] _, p@(SM a _ _ _ _))     = (xs, F2 a [] 1, p)
    go ':' (xs, F1 ds k, p)                    = (xs, F2 (k * (readR ds)) [] 1, p)
    go '-' (xs, F1 [] _, p)                    = (xs, F1 [] (-1), p)
    go d   (xs, F1 ds k, p) | isDigit d        = (xs, F1 (d : ds) k, p)
    go ';' (xs, F1 [] k, p)                    = (xs |> p, F1 [] k, p)
    go ';' (xs, F1 ds k, SM _ b c d e)         = let p' = SM (k * (readR ds)) b c d e in (xs |> p', F1 [] 1, p')

    go '-' (xs, F2 a [] _, p)                  = (xs, F2 a [] (-1), p)
    go d   (xs, F2 a ds k, p) | isDigit d      = (xs, F2 a (d : ds) k, p)
    go ':' (xs, F2 a [] _, p@(SM _ b _ _ _))   = (xs, F3 a b [] 1, p)
    go ':' (xs, F2 a ds k, p)                  = (xs, F3 a (k * (readR ds)) [] 1, p)
    go ';' (xs, F2 a [] _, SM _ b c d e)       = let p' = SM a b c d e in (xs |> p', F1 [] 1, p')
    go ';' (xs, F2 a ds k, SM _ _ c d e)       = let p' = SM a (k * (readR ds)) c d e in
                                                 (xs |> p', F1 [] 1, p')

    go d   (xs, F3 a b ds k, p) | isDigit d    = (xs, F3 a b (d : ds) k, p)
    go '-' (xs, F3 a b [] _, p)                = (xs, F3 a b [] (-1), p)
    go ':' (xs, F3 a b [] _, p@(SM _ _ c _ _)) = (xs, F4 a b c Nothing, p)
    go ':' (xs, F3 a b ds k, p)                = (xs, F4 a b (k * (readR ds)) Nothing, p)
    go ';' (xs, F3 a b [] _, SM _ _ c d e)     = let p' = SM a b c d e in (xs |> p', F1 [] 1, p')
    go ';' (xs, F3 a b ds k, SM _ _ _ d e)     = let p' = SM a b (k * (readR ds)) d e in
                                                 (xs |> p', F1 [] 1, p')

    go 'i' (xs, F4 a b c Nothing, p)           = (xs, F4 a b c (Just JumpInto), p)
    go 'o' (xs, F4 a b c Nothing, p)           = (xs, F4 a b c (Just JumpFrom), p)
    go '-' (xs, F4 a b c Nothing, p)           = (xs, F4 a b c (Just JumpRegular), p)
    go ':' (xs, F4 a b c (Just d),  p)         = (xs, F5 a b c d [], p)
    go ':' (xs, F4 a b c _, p@(SM _ _ _ d _))  = (xs, F5 a b c d [], p)
    go ';' (xs, F4 a b c _, SM _ _ _ d e)      = let p' = SM a b c d e in
                                                 (xs |> p', F1 [] 1, p')

    go d   (xs, F5 a b c j ds, p) | isDigit d  = (xs, F5 a b c j (d : ds), p)
    go ';' (xs, F5 a b c j [], _)              = let p' = SM a b c j (-1) in -- solc <0.6
                                                 (xs |> p', F1 [] 1, p')
    go ';' (xs, F5 a b c j ds, _)              = let p' = SM a b c j (readR ds) in -- solc >=0.6
                                                 (xs |> p', F1 [] 1, p')

    go c (xs, state, p)                      = (xs, error ("srcmap: y u " ++ show c ++ " in state" ++ show state ++ "?!?"), p)

makeSourceCache :: [(Text, Maybe ByteString)] -> Map Text Value -> IO SourceCache
makeSourceCache paths asts = do
  let f (_,  Just content) = return content
      f (fp, Nothing) = BS.readFile $ Text.unpack fp
  xs <- mapM f paths
  return $! SourceCache
    { files = zip (fst <$> paths) xs
    , lines = map (Vector.fromList . BS.split 0xa) xs
    , asts  = asts
    }

lineSubrange ::
  Vector ByteString -> (Int, Int) -> Int -> Maybe (Int, Int)
lineSubrange xs (s1, n1) i =
  let
    ks = Vector.map (\x -> 1 + BS.length x) xs
    s2  = Vector.sum (Vector.take i ks)
    n2  = ks Vector.! i
  in
    if s1 + n1 < s2 || s1 > s2 + n2
    then Nothing
    else Just (s1 - s2, min (s2 + n2 - s1) n1)

readSolc :: FilePath -> IO (Maybe (Map Text SolcContract, SourceCache))
readSolc fp =
  (readJSON <$> readFile fp) >>=
    \case
      Nothing -> return Nothing
      Just (contracts, asts, sources) -> do
        sourceCache <- makeSourceCache sources asts
        return (Just (contracts, sourceCache))

yul :: Text -> Text -> IO (Maybe ByteString)
yul contract src = do
  (json, path) <- yul' src
  let f = (json ^?! key "contracts") ^?! key (Key.fromText path)
      c = f ^?! key (Key.fromText $ if Text.null contract then "object" else contract)
      bytecode = c ^?! key "evm" ^?! key "bytecode" ^?! key "object" . _String
  pure $ toCode <$> (Just bytecode)

yulRuntime :: Text -> Text -> IO (Maybe ByteString)
yulRuntime contract src = do
  (json, path) <- yul' src
  let f = (json ^?! key "contracts") ^?! key (Key.fromText path)
      c = f ^?! key (Key.fromText $ if Text.null contract then "object" else contract)
      bytecode = c ^?! key "evm" ^?! key "deployedBytecode" ^?! key "object" . _String
  pure $ toCode <$> (Just bytecode)

solidity :: Text -> Text -> IO (Maybe ByteString)
solidity contract src = do
  (json, path) <- solidity' src
  let (sol, _, _) = fromJust $ readJSON json
  pure $ Map.lookup (path <> ":" <> contract) sol <&> (.creationCode)

solcRuntime :: Text -> Text -> IO (Maybe ByteString)
solcRuntime contract src = do
  (json, path) <- solidity' src
  let (sol, _, _) = fromJust $ readJSON json
  pure $ Map.lookup (path <> ":" <> contract) sol <&> (.runtimeCode)

functionAbi :: Text -> IO Method
functionAbi f = do
  (json, path) <- solidity' ("contract ABI { function " <> f <> " public {}}")
  let (sol, _, _) = fromJust $ readJSON json
  case Map.toList $ (fromJust (Map.lookup (path <> ":ABI") sol)).abiMap of
     [(_,b)] -> return b
     _ -> error "hevm internal error: unexpected abi format"

force :: String -> Maybe a -> a
force s = fromMaybe (error s)

readJSON :: Text -> Maybe (Map Text SolcContract, Map Text Value, [(Text, Maybe ByteString)])
readJSON json = case json ^? key "sourceList" of
  Nothing -> readStdJSON json
  _ -> readCombinedJSON json

-- deprecate me soon
readCombinedJSON :: Text -> Maybe (Map Text SolcContract, Map Text Value, [(Text, Maybe ByteString)])
readCombinedJSON json = do
  contracts <- f . KeyMap.toHashMapText <$> (json ^? key "contracts" . _Object)
  sources <- toList . fmap (view _String) <$> json ^? key "sourceList" . _Array
  return (contracts, Map.fromList (HMap.toList asts), [ (x, Nothing) | x <- sources])
  where
    asts = KeyMap.toHashMapText $ fromMaybe (error "JSON lacks abstract syntax trees.") (json ^? key "sources" . _Object)
    f x = Map.fromList . HMap.toList $ HMap.mapWithKey g x
    g s x =
      let
        theRuntimeCode = toCode (x ^?! key "bin-runtime" . _String)
        theCreationCode = toCode (x ^?! key "bin" . _String)
        abis = toList $ case (x ^?! key "abi") ^? _Array of
                 Just v -> v                                       -- solc >= 0.8
                 Nothing -> (x ^?! key "abi" . _String) ^?! _Array -- solc <  0.8
      in SolcContract {
        runtimeCode      = theRuntimeCode,
        creationCode     = theCreationCode,
        runtimeCodehash  = keccak' (stripBytecodeMetadata theRuntimeCode),
        creationCodehash = keccak' (stripBytecodeMetadata theCreationCode),
        runtimeSrcmap    = force "internal error: srcmap-runtime" (makeSrcMaps (x ^?! key "srcmap-runtime" . _String)),
        creationSrcmap   = force "internal error: srcmap" (makeSrcMaps (x ^?! key "srcmap" . _String)),
        contractName = s,
        constructorInputs = mkConstructor abis,
        abiMap       = mkAbiMap abis,
        eventMap     = mkEventMap abis,
        errorMap     = mkErrorMap abis,
        storageLayout = mkStorageLayout $ x ^? key "storage-layout",
        immutableReferences = mempty -- TODO: deprecate combined-json
      }

readStdJSON :: Text -> Maybe (Map Text SolcContract, Map Text Value, [(Text, Maybe ByteString)])
readStdJSON json = do
  contracts <- KeyMap.toHashMapText <$> json ^? key "contracts" . _Object
  -- TODO: support the general case of "urls" and "content" in the standard json
  sources <- KeyMap.toHashMapText <$>  json ^? key "sources" . _Object
  let asts = force "JSON lacks abstract syntax trees." . preview (key "ast") <$> sources
      contractMap = f contracts
      contents src = (src, encodeUtf8 <$> HMap.lookup src (mconcat $ Map.elems $ snd <$> contractMap))
  return (fst <$> contractMap, Map.fromList (HMap.toList asts), contents <$> (sort $ HMap.keys sources))
  where
    f :: (AsValue s) => HMap.HashMap Text s -> (Map Text (SolcContract, (HMap.HashMap Text Text)))
    f x = Map.fromList . (concatMap g) . HMap.toList $ x
    g (s, x) = h s <$> HMap.toList (KeyMap.toHashMapText (view _Object x))
    h :: Text -> (Text, Value) -> (Text, (SolcContract, HMap.HashMap Text Text))
    h s (c, x) =
      let
        evmstuff = x ^?! key "evm"
        runtime = evmstuff ^?! key "deployedBytecode"
        creation =  evmstuff ^?! key "bytecode"
        theRuntimeCode = toCode $ fromMaybe "" $ runtime ^? key "object" . _String
        theCreationCode = toCode $ fromMaybe "" $ creation ^? key "object" . _String
        srcContents :: Maybe (HMap.HashMap Text Text)
        srcContents = do metadata <- x ^? key "metadata" . _String
                         srcs <- KeyMap.toHashMapText <$> metadata ^? key "sources" . _Object
                         return $ (view (key "content" . _String)) <$> (HMap.filter (isJust . preview (key "content")) srcs)
        abis = force ("abi key not found in " <> show x) $
          toList <$> x ^? key "abi" . _Array
      in (s <> ":" <> c, (SolcContract {
        runtimeCode      = theRuntimeCode,
        creationCode     = theCreationCode,
        runtimeCodehash  = keccak' (stripBytecodeMetadata theRuntimeCode),
        creationCodehash = keccak' (stripBytecodeMetadata theCreationCode),
        runtimeSrcmap    = force "internal error: srcmap-runtime" (makeSrcMaps (runtime ^?! key "sourceMap" . _String)),
        creationSrcmap   = force "internal error: srcmap" (makeSrcMaps (creation ^?! key "sourceMap" . _String)),
        contractName = s <> ":" <> c,
        constructorInputs = mkConstructor abis,
        abiMap        = mkAbiMap abis,
        eventMap      = mkEventMap abis,
        errorMap      = mkErrorMap abis,
        storageLayout = mkStorageLayout $ x ^? key "storageLayout",
        immutableReferences = fromMaybe mempty $
          do x' <- runtime ^? key "immutableReferences"
             case fromJSON x' of
               Success a -> return a
               _ -> Nothing
      }, fromMaybe mempty srcContents))

mkAbiMap :: [Value] -> Map Word32 Method
mkAbiMap abis = Map.fromList $
  let
    relevant = filter (\y -> "function" == y ^?! key "type" . _String) abis
    f abi =
      (abiKeccak (encodeUtf8 (signature abi)),
       Method { name = abi ^?! key "name" . _String
              , methodSignature = signature abi
              , inputs = map parseMethodInput
                 (toList (abi ^?! key "inputs" . _Array))
              , output = map parseMethodInput
                 (toList (abi ^?! key "outputs" . _Array))
              , mutability = parseMutability
                 (abi ^?! key "stateMutability" . _String)
              })
  in f <$> relevant

mkEventMap :: [Value] -> Map W256 Event
mkEventMap abis = Map.fromList $
  let
    relevant = filter (\y -> "event" == y ^?! key "type" . _String) abis
    f abi =
     ( keccak' (encodeUtf8 (signature abi))
     , Event
       (abi ^?! key "name" . _String)
       (case abi ^?! key "anonymous" . _Bool of
         True -> Anonymous
         False -> NotAnonymous)
       (map (\y ->
        ( y ^?! key "name" . _String
        , force "internal error: type" (parseTypeName' y)
        , if y ^?! key "indexed" . _Bool
          then Indexed
          else NotIndexed
        ))
       (toList $ abi ^?! key "inputs" . _Array))
     )
  in f <$> relevant

mkErrorMap :: [Value] -> Map W256 SolError
mkErrorMap abis = Map.fromList $
  let
    relevant = filter (\y -> "error" == y ^?! key "type" . _String) abis
    f abi =
     ( stripKeccak $ keccak' (encodeUtf8 (signature abi))
     , SolError
       (abi ^?! key "name" . _String)
       (map (force "internal error: type" . parseTypeName')
       (toList $ abi ^?! key "inputs" . _Array))
     )
  in f <$> relevant
  where
    stripKeccak :: W256 -> W256
    stripKeccak = read . take 10 . show

mkConstructor :: [Value] -> [(Text, AbiType)]
mkConstructor abis =
  let
    isConstructor y =
      "constructor" == y ^?! key "type" . _String
  in
    case filter isConstructor abis of
      [abi] -> map parseMethodInput (toList (abi ^?! key "inputs" . _Array))
      [] -> [] -- default constructor has zero inputs
      _  -> error "strange: contract has multiple constructors"

mkStorageLayout :: Maybe Value -> Maybe (Map Text StorageItem)
mkStorageLayout Nothing = Nothing
mkStorageLayout (Just json) = do
  items <- json ^? key "storage" . _Array
  types <- json ^? key "types"
  fmap Map.fromList (forM (Vector.toList items) $ \item ->
    do name <- item ^? key "label" . _String
       offset <- item ^? key "offset" . _Number >>= toBoundedInteger
       slot <- item ^? key "slot" . _String
       typ <- Key.fromText <$> item ^? key "type" . _String
       slotType <- types ^?! key typ ^? key "label" . _String
       return (name, StorageItem (read $ Text.unpack slotType) offset (read $ Text.unpack slot)))

signature :: AsValue s => s -> Text
signature abi =
  case abi ^?! key "type" of
    "fallback" -> "<fallback>"
    _ ->
      fold [
        fromMaybe "<constructor>" (abi ^? key "name" . _String), "(",
        intercalate ","
          (map (\x -> x ^?! key "type" . _String)
            (toList $ abi ^?! key "inputs" . _Array)),
        ")"
      ]

-- Helper function to convert the fields to the desired type
parseTypeName' :: AsValue s => s -> Maybe AbiType
parseTypeName' x =
  parseTypeName
    (fromMaybe mempty $ x ^? key "components" . _Array . to parseComponents)
    (x ^?! key "type" . _String)
  where parseComponents = fmap $ snd . parseMethodInput

parseMutability :: Text -> Mutability
parseMutability "view" = View
parseMutability "pure" = Pure
parseMutability "nonpayable" = NonPayable
parseMutability "payable" = Payable
parseMutability _ = error "unknown function mutability"

-- This actually can also parse a method output! :O
parseMethodInput :: AsValue s => s -> (Text, AbiType)
parseMethodInput x =
  ( x ^?! key "name" . _String
  , force "internal error: method type" (parseTypeName' x)
  )

containsLinkerHole :: Text -> Bool
containsLinkerHole = regexMatches "__\\$[a-z0-9]{34}\\$__"

toCode :: Text -> ByteString
toCode t = case BS16.decodeBase16 (encodeUtf8 t) of
  Right d -> d
  Left e -> if containsLinkerHole t
            then error "unlinked libraries detected in bytecode"
            else error $ Text.unpack e

solidity' :: Text -> IO (Text, Text)
solidity' src = withSystemTempFile "hevm.sol" $ \path handle -> do
  hClose handle
  writeFile path ("//SPDX-License-Identifier: UNLICENSED\n" <> "pragma solidity ^0.8.6;\n" <> src)
  writeFile (path <> ".json")
    [Here.i|
    {
      "language": "Solidity",
      "sources": {
        ${path}: {
          "urls": [
            ${path}
          ]
        }
      },
      "settings": {
        "outputSelection": {
          "*": {
            "*": [
              "metadata",
              "evm.bytecode",
              "evm.deployedBytecode",
              "abi",
              "storageLayout",
              "evm.bytecode.sourceMap",
              "evm.bytecode.linkReferences",
              "evm.bytecode.generatedSources",
              "evm.deployedBytecode.sourceMap",
              "evm.deployedBytecode.linkReferences",
              "evm.deployedBytecode.generatedSources"
            ],
            "": [
              "ast"
            ]
          }
        }
      }
    }
    |]
  x <- pack <$>
    readProcess
      "solc"
      ["--allow-paths", path, "--standard-json", (path <> ".json")]
      ""
  return (x, pack path)

yul' :: Text -> IO (Text, Text)
yul' src = withSystemTempFile "hevm.yul" $ \path handle -> do
  hClose handle
  writeFile path src
  writeFile (path <> ".json")
    [Here.i|
    {
      "language": "Yul",
      "sources": { ${path}: { "urls": [ ${path} ] } },
      "settings": { "outputSelection": { "*": { "*": ["*"], "": [ "*" ] } } }
    }
    |]
  x <- pack <$>
    readProcess
      "solc"
      ["--allow-paths", path, "--standard-json", (path <> ".json")]
      ""
  return (x, pack path)

solc :: Language -> Text -> IO Text
solc lang src =
  withSystemTempFile "hevm.sol" $ \path handle -> do
    hClose handle
    writeFile path (stdjson lang src)
    Text.pack <$> readProcess
      "solc"
      ["--standard-json", path]
      ""

data Language = Solidity | Yul
  deriving (Show)

data StandardJSON = StandardJSON Language Text
-- more options later perhaps

instance ToJSON StandardJSON where
  toJSON (StandardJSON lang src) =
    object [ "language" .= show lang
           , "sources" .= object ["hevm.sol" .=
                                   object ["content" .= src]]
           , "settings" .=
             object [ "outputSelection" .=
                    object ["*" .=
                      object ["*" .= (toJSON
                              ["metadata" :: String,
                               "evm.bytecode",
                               "evm.deployedBytecode",
                               "abi",
                               "storageLayout",
                               "evm.bytecode.sourceMap",
                               "evm.bytecode.linkReferences",
                               "evm.bytecode.generatedSources",
                               "evm.deployedBytecode.sourceMap",
                               "evm.deployedBytecode.linkReferences",
                               "evm.deployedBytecode.generatedSources",
                               "evm.deployedBytecode.immutableReferences"
                              ]),
                              "" .= (toJSON ["ast" :: String])
                             ]
                            ]
                    ]
           ]

stdjson :: Language -> Text -> Text
stdjson lang src = decodeUtf8 $ toStrict $ encode $ StandardJSON lang src

-- | When doing CREATE and passing constructor arguments, Solidity loads
-- the argument data via the creation bytecode, since there is no "calldata"
-- for CREATE.
--
-- This interferes with our ability to look up the current contract by
-- codehash, so we must somehow strip away this extra suffix. Luckily
-- we can detect the end of the actual bytecode by looking for the
-- "metadata hash". (Not 100% correct, but works in practice.)
--
-- Actually, we strip away the entire BZZR suffix too, because as long
-- as the codehash matches otherwise, we don't care if there is some
-- difference there.
stripBytecodeMetadata :: ByteString -> ByteString
stripBytecodeMetadata bs =
  let stripCandidates = flip BS.breakSubstring bs <$> knownBzzrPrefixes in
    case find ((/= mempty) . snd) stripCandidates of
      Nothing -> bs
      Just (b, _) -> b

stripBytecodeMetadataSym :: [Expr Byte] -> [Expr Byte]
stripBytecodeMetadataSym b =
  let
    concretes :: [Maybe Word8]
    concretes = unlitByte <$> b
    bzzrs :: [[Maybe Word8]]
    bzzrs = fmap (Just) . BS.unpack <$> knownBzzrPrefixes
    candidates = (flip Data.List.isInfixOf concretes) <$> bzzrs
  in case elemIndex True candidates of
    Nothing -> b
    Just i -> let ind = fromJust $ infixIndex (bzzrs !! i) concretes
              in take ind b

infixIndex :: (Eq a) => [a] -> [a] -> Maybe Int
infixIndex needle haystack = findIndex (isPrefixOf needle) (tails haystack)

knownBzzrPrefixes :: [ByteString]
knownBzzrPrefixes = [
  -- a1 65 "bzzr0" 0x58 0x20 (solc <= 0.5.8)
  BS.pack [0xa1, 0x65, 98, 122, 122, 114, 48, 0x58, 0x20],
  -- a2 65 "bzzr0" 0x58 0x20 (solc >= 0.5.9)
  BS.pack [0xa2, 0x65, 98, 122, 122, 114, 48, 0x58, 0x20],
  -- a2 65 "bzzr1" 0x58 0x20 (solc >= 0.5.11)
  BS.pack [0xa2, 0x65, 98, 122, 122, 114, 49, 0x58, 0x20],
  -- a2 64 "ipfs" 0x58 0x22 (solc >= 0.6.0)
  BS.pack [0xa2, 0x64, 0x69, 0x70, 0x66, 0x73, 0x58, 0x22]
  ]

-- | Every node in the AST has an ID, and other nodes reference those
-- IDs.  This function recurses through the tree looking for objects
-- with the "id" key and makes a big map from ID to value.
astIdMap :: Foldable f => f Value -> Map Int Value
astIdMap = foldMap f
  where
    f :: Value -> Map Int Value
    f (Array x) = foldMap f x
    f v@(Object x) =
      let t = foldMap f (KeyMap.elems x)
      in case KeyMap.lookup "id" x of
        Nothing         -> t
        Just (Number i) -> t <> Map.singleton (round i) v
        Just _          -> t
    f _ = mempty

astSrcMap :: Map Int Value -> (SrcMap -> Maybe Value)
astSrcMap astIds =
  \(SM i n f _ _)  -> Map.lookup (i, n, f) tmp
  where
    tmp :: Map (Int, Int, Int) Value
    tmp =
       Map.fromList
      . mapMaybe
        (\v -> do
          src <- preview (key "src" . _String) v
          [i, n, f] <- mapM (readMaybe . Text.unpack) (Text.split (== ':') src)
          return ((i, n, f), v)
        )
      . Map.elems
      $ astIds
