module Verilog
  ( run
  ) where

import Control.Exception.Base
import Data.Array
import Data.Bits
import qualified Data.Foldable as Foldable
import Data.Functor
import qualified Data.Map.Strict as Map
import Data.Maybe
import System.Directory
import System.FilePath
import System.IO

import Operators
import Ranged
import VInt
import SymbolTable

import qualified Parser as P
import qualified Expressions as E
import qualified Records as R

showBitSel :: E.Slice -> String
showBitSel (E.Slice a b) =
  if a == 0 && b == 0 then ""
  else "[" ++ show a ++ ":" ++ show b ++ "]"

showBitSels :: [E.Slice] -> [String]
showBitSels slices = map expand raw
  where raw = map showBitSel slices
        width = maximum $ map length raw
        expand s = assert (length s <= width) $
                   s ++ replicate (width - length s) ' '

showPorts :: [(Ranged P.Symbol, Ranged E.Slice)] -> [String]
showPorts entries = map draw $ zip names sels
  where names = [P.Symbol "clk", P.Symbol "rst_n"] ++
                map (rangedData . fst) entries
        sels = showBitSels $ ([slice0, slice0] ++
                              map (rangedData . snd) entries)
        slice0 = E.Slice 0 0
        draw (sym, sel) = "input wire " ++ sel ++ " " ++ P.symName sym

fileHeader :: String
fileHeader =
  unlines [ "// AUTO-GENERATED FILE: Do not edit."
          , ""
          , "`default_nettype none"
          , ""
          ]

fileFooter :: String
fileFooter = "`default_nettype wire\n"

imports :: String
imports =
  unlines [ "  import \"DPI-C\" context acov_record ="
          , "    function void acov_record (input string name, input longint value);"
          , "  import \"DPI-C\" function void acov_close ();"
          , ""
          , "`ifndef NO_FINAL"
          , "  final acov_close ();"
          , "`endif"
          , ""
          ]

beginModule :: Handle -> String -> SymbolTable (Ranged E.Slice) -> IO ()
beginModule handle name ports =
  assert (not $ null portStrs) $
  print fileHeader >>
  print start >>
  print (head portStrs) >>
  mapM_ (\ str -> print indent >> print str) (tail portStrs) >>
  print ");\n\n" >>
  print imports
  where print = hPutStr handle
        start = "module " ++ name ++ "_coverage ("
        indent = ",\n" ++ replicate (length start) ' '
        portStrs = showPorts $ stAssocs ports

-- TODO: This doesn't know about associativity.
parenthesize :: Int -> String -> Int -> String
parenthesize this str that = if this <= that then "(" ++ str ++ ")" else str

symName :: SymbolTable a -> Symbol -> String
symName st sym = P.symName $ rangedData $ stNameAt sym st

showExpression :: SymbolTable (Ranged E.Slice) -> Int -> Ranged E.Expression -> String
showExpression syms that rexpr =
  let (this, str) = showExpression' syms (rangedData rexpr) in
    parenthesize this str that

showExpression' :: SymbolTable (Ranged E.Slice) -> E.Expression -> (Int, String)

showExpression' syms (E.ExprSym sym) = (100, symName syms sym)

showExpression' _ (E.ExprInt vint) = (100, printVInt vint)

showExpression' syms (E.ExprSel rsym ra rb) =
  (100, symName syms (rangedData rsym) ++ "[" ++
        se ra ++ (case rb of Nothing -> "]" ; Just rb' -> ":" ++ se rb' ++ "]"))
  where se = showExpression syms 1

showExpression' syms (E.ExprConcat re0 res) =
  (100,
   "{" ++ se re0 ++ concatMap (\ re -> ", " ++ se re) res ++ "}")
  where se = showExpression syms 14

showExpression' syms (E.ExprReplicate n re) =
  (100, "{" ++ show n ++ "{" ++ showExpression syms 13 re ++ "}}")

showExpression' syms (E.ExprUnOp ruo re) =
  (prec, showUnOp uo ++ " " ++ showExpression syms prec re)
  where uo = rangedData ruo
        prec = unOpPrecedence uo

showExpression' syms (E.ExprBinOp rbo ra rb) =
  (prec, se ra ++ " " ++ showBinOp bo ++ " " ++ se rb)
  where bo = rangedData rbo
        prec = binOpPrecedence bo
        se = showExpression syms prec

showExpression' syms (E.ExprCond ra rb rc) =
  (1, se ra ++ " ? " ++ se rb ++ " : " ++ se rc)
  where se = showExpression syms 1

showExpression64 :: Int -> SymbolTable (Ranged E.Slice) ->
                    Ranged E.Expression -> String
showExpression64 w syms rexpr =
  if w /= 64 then "{" ++ show (64 - w) ++ "'b0, " ++ rest ++ "}"
  else rest
  where rest = showExpression syms 0 rexpr

writeWire :: Handle -> SymbolTable (Ranged E.Slice) -> (Int, R.Group) ->
             IO (Maybe (Ranged E.Expression), Int)
writeWire handle syms (idx, grp) =
  assert (width > 0)
  put "  wire [" >>
  put (show $ width - 1) >>
  put ":0] " >>
  put name >>
  put (show idx) >>
  put ";\n  assign " >>
  put name >>
  put " = " >>
  put (snd $ showExpression' syms (E.ExprConcat (head exprs) (tail exprs))) >>
  put ";\n" >>
  return (R.grpGuard grp, width)
  where put = hPutStr handle
        name = "acov_recgroup_" ++ show idx
        width = sum $ Foldable.toList (R.grpST grp)
        exprs = map (fst . snd) (Map.toAscList (R.grpRecs grp))

startAlways :: Handle -> IO ()
startAlways handle =
  put "  always @(posedge clk or negedge rst_n) begin\n" >>
  put "    if (rst_n) begin\n"
  where put = hPutStr handle 

startGuard :: Handle -> SymbolTable (Ranged E.Slice) ->
              Maybe (Ranged E.Expression) -> IO Bool
startGuard _ _ Nothing = return False
startGuard handle syms (Just guard) =
  hPutStr handle "if (" >>
  hPutStr handle (showExpression syms 100 guard) >>
  hPutStr handle ") begin\n" >>
  return True

endGuard :: Handle -> Bool -> IO ()
endGuard _ False = return ()
endGuard handle True = hPutStr handle "      end\n"

showRecArgs :: Int -> Int -> String
showRecArgs idx width =
  assert (width > 0)
  "{" ++
  (if pad >= 0 then
     show pad ++ "'b0, " ++ slice (width - 1) (width + pad - 64)
   else
     "") ++
  rst False (quot width 64) ++ "}"
  where pad = 63 - rem (width + 63) 64
        name = "acov_recgroup_" ++ show idx
        slice top bot = name ++ "[" ++ show top ++ ":" ++ show bot ++ "]"
        rst _ 0 = ""
        rst comma nleft =
          (if comma then ", " else "") ++
          slice (64 * nleft - 1) (64 * (nleft - 1)) ++
          rst True (nleft - 1)

writeGroup :: Handle -> String -> SymbolTable (Ranged E.Slice) ->
              (Int, (Maybe (Ranged E.Expression), Int)) -> IO ()
writeGroup handle modname syms (idx, (guard, width)) =
  -- TODO: We need a pass to guarantee the assertions hold
  assert (nwords > 0)
  assert (nwords <= 4) $
  do { guarded <- startGuard handle syms guard
     ; put $ if guarded then "  " else "" ++ "      acov_record"
     ; put $ show nwords
     ; put $ " (\"" ++ modname ++ "." ++ show idx ++ ", "
     ; put $ showRecArgs idx width
     ; put ");\n"
     ; endGuard handle guarded
     }
  where put = hPutStr handle
        nwords = quot (width + 63) 64

endModule :: Handle -> IO ()
endModule handle = put "    end\n  end\nendmodule\n\n" >> put fileFooter
  where put = hPutStr handle

modName :: R.Module -> String
modName = P.symName . rangedData . R.modName

writeModule :: R.Module -> Handle -> IO ()
writeModule mod handle =
  do { beginModule handle name syms
     ; grps <- mapM (writeWire handle syms) (zip [0..] (R.modGroups mod))
     ; startAlways handle
     ; mapM_ (writeGroup handle name syms) (zip [0..] grps)
     ; endModule handle
     }
  where syms = R.modSyms mod
        name = modName mod

dumpModule :: FilePath -> R.Module -> IO ()
dumpModule dirname mod =
  withFile (dirname </> (modName mod ++ "_coverage.v")) WriteMode
  (writeModule mod)

run :: FilePath -> [R.Module] -> IO ()
run dirname mods = createDirectoryIfMissing False dirname >>
                   mapM_ (dumpModule dirname) mods