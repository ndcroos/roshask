-- |Generate Haskell source files for ROS .msg types. Currently only
-- supports arrays of built-in types.
{-# LANGUAGE OverloadedStrings #-}
module Ros.Core.Msg.Gen (generateMsgType) where
import Control.Applicative ((<$>), (<*>))
import Control.Monad ((>=>))
import Data.ByteString.Char8 (pack, ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (toUpper)
import Data.Maybe (fromJust)
import Data.Set (Set, singleton)
import qualified Data.Set as S
import Data.List (foldl')
import Ros.Core.Msg.Analysis (MsgInfo, SerialInfo(..), withMsg, isFlat, 
                              getTypeInfo, liftIO)
import Ros.Core.Msg.Types

generateMsgType :: ByteString -> [ByteString] -> Msg -> MsgInfo ByteString
generateMsgType pkgPath pkgMsgs msg@(Msg name _ _ fields _) =
  do (fDecls, binInst, st, cons) <- withMsg msg $
                                    (,,,) <$> mapM generateField fields
                                          <*> genBinaryInstance msg
                                          <*> genStorableInstance msg
                                          <*> genConstants msg
     let fieldSpecs = B.intercalate lineSep fDecls
         (storableImport, storableInstance) = st
     msgHash <- liftIO $ genHasHash msg
     return $ B.concat [ modLine, "\n"
                       , imports
                       , storableImport
                       , dataLine, fieldSpecs, " } deriving P.Show\n\n"
                       , binInst, "\n\n"
                       , storableInstance
                       , genHasHeader msg
                       , msgHash
                       , cons ]
    where tName = pack $ toUpper (head name) : tail name
          modLine = B.concat ["{-# LANGUAGE OverloadedStrings #-}\n",
                              "module ", pkgPath, tName, " where"]
          imports = B.concat ["import qualified Prelude as P\n",
                              "import Prelude ((.), (+))\n",
                              "import Control.Applicative\n",
                              "import Ros.Core.RosBinary\n",
                              "import Ros.Core.Msg.MsgInfo\n",
                              genImports pkgPath pkgMsgs (map snd fields)]
          dataLine = B.concat ["\ndata ", tName, " = ", tName, " { "]
          fieldIndent = B.replicate (B.length dataLine - 3) ' '
          lineSep = B.concat ["\n", fieldIndent, ", "]

hasHeader :: Msg -> Bool
hasHeader msg = case fields msg of
                  ((_, RUserType "Header"):_) -> True
                  _ -> False

genHasHeader :: Msg -> ByteString
genHasHeader m@(Msg name _ _ fields _) = 
    if hasHeader m
    then let hn = fst (head fields) -- The header field name
         in B.concat ["instance HasHeader ", pack name, " where\n",
                      "  getSequence = Header.seq . ", hn, "\n",
                      "  getFrame = Header.frame_id . ", hn, "\n",
                      "  getStamp = Header.stamp . " , hn, "\n",
                      "  setSequence seq x' = x' { ", hn, 
                      " = (", hn, " x') { Header.seq = seq } }\n\n"]
    else ""

genHasHash :: Msg -> IO ByteString
genHasHash (Msg sname lname md5 _ _) = 
    md5 >>= \md5 -> return $
        B.concat ["instance MsgInfo ", pack sname,
                  " where\n  sourceMD5 _ = \"", pack md5,
                  "\"\n  msgTypeName _ = \"", pack lname,
                  "\"\n"]

generateField :: (ByteString, MsgType) -> MsgInfo ByteString
generateField (name, t) = do t' <- hType <$> getTypeInfo t
                             return $ B.concat [name, " :: ", t']

genImports :: ByteString -> [ByteString] -> [MsgType] -> ByteString
genImports pkgPath pkgMsgs fieldTypes = 
    B.concat $ concatMap (\i -> ["import ", i, "\n"])
                         (S.toList (allImports fieldTypes))
    where getDeps = typeDependency pkgPath pkgMsgs
          allImports = foldl' ((. getDeps) . flip S.union) S.empty

genBinaryInstance :: Msg -> MsgInfo ByteString
genBinaryInstance m@(Msg name _ _ fields _) = 
    do puts <- mapM (\(f,t) -> serialize t >>= return . buildPut f) fields
       gets <- mapM (deserialize . snd) fields
       return $ B.concat ["instance RosBinary ", pack name, " where\n",
                          "  put obj' = ", B.intercalate " *> " puts,"\n",
                          "  get = ", pack name, " <$> ", 
                          B.intercalate " <*> " gets,
                          if hasHeader m then putMsgHeader else ""]
    where buildPut f ser = B.concat [ser, " (", f, " obj')"]

genStorableInstance :: Msg -> MsgInfo (ByteString, ByteString)
genStorableInstance msg = isFlat msg >>= aux
    where aux False = return ("", "")
          aux True = do sz <- totalSize msg
                        return (smImp, stInst sz)
          peekFields = map (const "SM.peek") (fields msg)
          pokeFields = map (\(n,_) -> B.concat ["SM.poke (", n, " obj')"]) 
                           (fields msg)
          name = pack (shortName msg)
          stInst sz = B.concat ["instance Storable ", name, " where\n",
                                "  sizeOf _ = ", sz,"\n",
                                "  alignment _ = 8\n",
                                "  peek = SM.runStorable (", name, " <$> ",
                                B.intercalate " <*> " peekFields, ")\n",
                                "  poke ptr' obj' = ",
                                "SM.runStorable store' ptr'\n",
                                "    where store' = ",
                                B.intercalate " *> " pokeFields,"\n\n"]
          smImp = B.concat [ "import Foreign.Storable (Storable(..))\n"
                           , "import qualified Ros.Core.Util.StorableMonad"
                           , " as SM\n" ]

totalSize :: Msg -> MsgInfo ByteString
totalSize msg = B.intercalate sep <$> mapM (aux . snd) (fields msg)
    where aux = getTypeInfo >=> return . fromJust . size
          sep = B.append " +\n" $ B.replicate 13 ' '

putMsgHeader :: ByteString
putMsgHeader = "\n  putMsg = putStampedMsg"

serialize :: MsgType -> MsgInfo ByteString
serialize = getTypeInfo >=> return . putField

deserialize :: MsgType -> MsgInfo ByteString
deserialize = getTypeInfo >=> return . getField

intImport, wordImport, vectorDeps :: Set ByteString
intImport = singleton "qualified Data.Int as Int"
wordImport = singleton "qualified Data.Word as Word"
vectorDeps = S.fromList [ "qualified Data.Vector.Storable as V" ]

-- Generate a 'Set' of modules to be imported for the specified
-- 'MsgType'. The first argumentis the package of the message type
-- currently being generated, the second argument is a list of all the
-- messages defined in that package (which can be referred to with
-- unqualified names), the third is the 'MsgType' to generate imports
-- for.
typeDependency :: ByteString -> [ByteString] -> MsgType -> Set ByteString
typeDependency _ _ RInt8                = intImport
typeDependency _ _ RUInt8               = wordImport
typeDependency _ _ RInt16               = intImport
typeDependency _ _ RUInt16              = wordImport
typeDependency _ _ RUInt32              = wordImport
typeDependency _ _ RTime                = singleton "Ros.Core.RosTypes"
typeDependency _ _ RDuration            = singleton "Ros.Core.RosTypes"
typeDependency p m (RFixedArray _ t)    = S.union vectorDeps $
                                       typeDependency p m t
typeDependency p m (RVarArray t)        = S.union vectorDeps $
                                       typeDependency p m t
typeDependency _ _ (RUserType "Header") = 
    S.fromList ["qualified Ros.Roslib.Header as Header", 
                "Ros.Core.Msg.HeaderSupport"]
typeDependency p m (RUserType ut)       = if elem ut m
                                          then singleton $ 
                                               B.concat ["qualified ", p, ut, 
                                                         " as ", ut]
                                          else path2Module ut
typeDependency _ _ _                    = S.empty

-- Non built-in types are either in the specified package or in the
-- Ros.Std_msgs namespace. If a package path is given, then it is
-- converted to a Haskell hierarchical module name and prefixed by
-- "Ros.".
path2Module :: ByteString -> Set ByteString
path2Module p 
    | B.elem '/' p = singleton $
                     B.concat ["qualified Ros.",
                               B.intercalate "." . map cap $ parts,
                               " as ", last parts]
    | otherwise    = singleton $
                     B.concat ["qualified Ros.Std_msgs.", p, " as ", p]
    where cap s = B.cons (toUpper (B.head s)) (B.tail s)
          parts = B.split '/' p

genConstants :: Msg -> MsgInfo ByteString
genConstants = fmap B.concat . mapM buildLine . constants
    where buildLine (name, rosType, val) = 
              do t <- hType <$> getTypeInfo rosType
                 return $ B.concat ["\n",name, " :: ", t, "\n", 
                                    name, " = ", val, "\n"]
