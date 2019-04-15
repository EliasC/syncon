{-# OPTIONS_GHC -fno-warn-unused-imports #-}

module Main where

import Pre

import Text.Show.Pretty (pPrint)

import qualified P1Lexing.Types as Lexer
import qualified P1Lexing.Lexer as Lexer

import qualified P2LanguageDefinition.Types as LD
import qualified P2LanguageDefinition.Parser as LD

synconTokens :: Lexer.LanguageTokens Text
synconTokens = Lexer.LanguageTokens
  -- Literal tokens
  [ "token", "=", "syncon", ":", "{", ";", "}", "prefix", "postfix", "infix", "#assoc"
  , "(", ")", "*", "+", "?", ".", "comment", "left", "right", "precedence", "except"
  , "type", "builtin", "forbid" ]
  -- Regex tokens
  [ ("Name", "[[:lower:]][[:word:]]*")
  , ("TypeName", "[[:upper:]][[:word:]]*")
  , ("String", "\"(\\\\.|[^\"\\\\])*\"") ]
  -- Comment regex
  "//[^\\n]*(\\n|$)"

lexTest :: IO ()
lexTest = do
  res <- Lexer.allOneLanguage @Text "SynconDef" synconTokens "examples/bootstrap.syncon"
  pPrint $ fmap Lexer.tokenText <$> res

parseTest :: IO ()
parseTest = do
  res <- LD.parseFile' "examples/bootstrap.syncon"
  pPrint res


main :: IO ()
main = parseTest
