module Main where

import Data.Monoid ((<>))
import Options.Applicative
import System.Exit

import ErrorsOr (ErrorsOr, reportEO)
import Parser (parseScript)
import qualified When
import qualified Symbols
import qualified Expressions
import qualified Width
import qualified Verilog

data Args = Args
  { input :: FilePath
  , odir  :: FilePath
  }

mainArgs :: Parser Args
mainArgs = Args
           <$> argument str ( metavar "input" <>
                              help "Input file" )
           <*> argument str ( metavar "odir" <>
                              help "Output directory" )

mainInfo :: ParserInfo Args
mainInfo = info (mainArgs <**> helper)
           ( fullDesc <>
             progDesc "Generate functional coverage bindings" <>
             header "acov - functional coverage bindings generator" )

runPass :: FilePath -> (a -> ErrorsOr b) -> a -> IO b
runPass path pass a = reportEO path (pass a)

run :: Args -> IO ()
run args = readFile path >>=
           runPass path (parseScript path) >>=
           runPass path When.run >>=
           runPass path Symbols.run >>=
           runPass path Expressions.run >>=
           runPass path Width.run >>=
           (\ scr -> Verilog.run (odir args) scr) >>
           exitSuccess
  where path = input args


main :: IO ()
main = execParser mainInfo >>= run