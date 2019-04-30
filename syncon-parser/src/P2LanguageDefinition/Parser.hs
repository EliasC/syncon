{-# LANGUAGE RecursiveDo #-}

module P2LanguageDefinition.Parser
( Error(..)
, SynconDefinitionLanguage(..)
, TokenKind(..)
, parseFile
) where

import Pre
import Result (Result(..))

import qualified Data.Text as Text
import qualified Data.Sequence as Seq
import qualified Data.HashSet as S

import Text.Earley (Grammar, (<?>), terminal, satisfy, rule, Report(..))
import qualified Text.Earley as Earley

import ErrorMessage (FormatError(..), simpleErrorMessage)

import P1Lexing.Types (Range(Nowhere), range, Token(..), textualToken)
import qualified P1Lexing.Lexer as Lexer
import P2LanguageDefinition.Types

data Error
  = LexingError (Lexer.Error Lang TokenKind)
  | UnexpectedToken (HashSet Text) Tok
  | UnexpectedEOF (HashSet Text)
  | AmbiguousParse -- TODO: this is very unsatisfactory, but I don't want to implement two versions of the ambiguity detection thing
  deriving (Show)

instance FormatError Error where
  formatError (LexingError e) = formatError e
  formatError (UnexpectedToken expected tok) = simpleErrorMessage (range tok) $
    "Unexpected token " <> textualToken tok <> ", expected one of:\n"
    <> (toList expected & sort & foldMap (<> "\n"))
  formatError (UnexpectedEOF expected) = simpleErrorMessage Nowhere $
    "Unexpected end of file, expected one of:\n"
    <> (toList expected & sort & foldMap (<> "\n"))
  formatError AmbiguousParse = simpleErrorMessage Nowhere "Got an ambiguous parse of the definition file, go complain to your local Viktor."

data SynconDefinitionLanguage = SynconDefinitionLanguage deriving (Eq, Generic, Show)

data TokenKind = NameTok | TypeNameTok | StringTok deriving (Eq, Generic, Show)

instance Hashable SynconDefinitionLanguage
instance Hashable TokenKind

type Lang = SynconDefinitionLanguage

-- Internal types
type Prod r a = Earley.Prod r Text Tok a
type Tok = Token Lang TokenKind

lexFile :: FilePath -> IO (Result [Lexer.Error Lang TokenKind] [Tok])
lexFile = case Lexer.allOneLanguage SynconDefinitionLanguage synconTokens of
  Error err -> compErr "P2LanguageDefinition.Parser.lexFile" $ show err
  Data fun -> fun

-- | Don't check for correctness in any way, just parse the file and return a list of top-level definitions
parseFile :: FilePath -> IO (Result [Error] [Top])
parseFile path = lex <&> \getTokens -> do
  tokens <- getTokens
  case Earley.fullParses (Earley.parser tops) tokens of
    ([], Report{expected, unconsumed = next : _}) -> Error [UnexpectedToken (S.fromList expected) next]
    ([], Report{expected, unconsumed = []}) -> Error [UnexpectedEOF $ S.fromList expected]
    ([res], _) -> return res  -- TODO: deal with other cases as well
    (_, _) -> Error [AmbiguousParse]
  where
    lex = lexFile path <&> first (fmap LexingError)

synconTokens :: Lexer.LanguageTokens TokenKind
synconTokens = Lexer.LanguageTokens
  -- Literal tokens
  [ "token", "=", "syncon", ":", "{", ";", "}", "prefix", "postfix", "infix", "#assoc"
  , "(", ")", "*", "+", "?", ".", "comment", "left", "right", "precedence", "except"
  , "type", "builtin", "forbid", "|" ]
  -- Regex tokens
  [ (NameTok, (Nowhere, "[[:lower:]][[:word:]]*"))
  , (TypeNameTok, (Nowhere, "[[:upper:]][[:word:]]*"))
  , (StringTok, (Nowhere, "\"(\\\\.|[^\"\\\\])*\"")) ]
  -- Comment regex
  [(Nowhere, "//[^\\n]*(\\n|$)")]

-- |
-- = Parsers for top level declarations

-- | Something to wrap all the disparate 'Top' parsers
tops :: Grammar r (Prod r [Top])
tops = mdo
  st <- fmap (SyntaxTypeTop >>> pure) <$> syntaxTypeDef
  tt <- fmap (TokenTypeTop >>> pure) <$> tokenTypeDef
  c <- fmap (CommentTop >>> pure) <$> commentDef
  f <- fmap (ForbidTop >>> pure) <$> forbidDef
  pl <- fmap (PrecedenceTop >>> pure) <$> precedenceDef
  syn <- fmap (SynconTop >>> pure) <$> synconDef
  pre <- fmap (SynconTop >>> pure) <$> prefixDef
  post <- fmap (SynconTop >>> pure) <$> postfixDef
  inf <- fmap (\(s, f') -> foldr (:) [SynconTop s] $ ForbidTop <$> f') <$> infixDef
  return . fmap concat . many $ st <|> tt <|> c <|> syn <|> pre <|> post <|> inf <|> f <|> pl

-- | Parse a syntax type declaration
syntaxTypeDef :: Grammar r (Prod r SyntaxType)
syntaxTypeDef = rule $ constr <$> lit "type" <*> tyName <?> "syntax type declaration"
  where
    constr start (r, tyn) = SyntaxType tyn (range start <> r)

-- | Parse a token type declaration
tokenTypeDef :: Grammar r (Prod r TokenType)
tokenTypeDef = rule $ constr <$> lit "token" <*> tyName <* lit "=" <*> string <?> "token type declaration"
  where
    constr start (_, tyn) regex@(end, _) = TokenType tyn regex (range start <> end)

-- | Parse a comment declaration
commentDef :: Grammar r (Prod r Comment)
commentDef = rule $ constr <$> lit "comment" <*> string <?> "comment declaration"
  where
    constr start regex@(end, _) = Comment regex (range start <> end)

forbidDef :: Grammar r (Prod r Forbid)
forbidDef = rule . (<?> "forbid disambiguation") $ do
  start <- lit "forbid"
  ~n <- name <* lit "."
  sdname <- (second (coerce >>> SDName) <$> name)
    <|> ((,SDLeft) . range <$> lit "left")
    <|> ((,SDRight) . range <$> lit "right")
  lit "="
  ~(end, n2) <- name
  pure $ Forbid (range start <> end) n sdname (end, n2)

precedenceDef :: Grammar r (Prod r PrecedenceList)
precedenceDef = rule . (<?> "precedence disambiguation list") $ do
  start <- lit "precedence" <* lit "{"
  pList <- innerList
  end <- lit "}"
  mExcept <- optional $ do
    lit "except" *> lit "{"
    eList <- innerList
    end' <- lit "}"
    pure (end', eList)
  pure $ PrecedenceList
    (range start <> range end <> foldMap (fst >>> range) mExcept)
    pList
    (foldMap snd mExcept)
  where
    innerList = Seq.fromList <$> some (Seq.fromList <$> some (snd <$> name) <* lit ";")

-- |
-- == Syncon definitions

-- | A basic syncon definition
synconDef :: Grammar r (Prod r Syncon)
synconDef = syntaxDescription >>= \description -> rule . (<?> "syncon definition") $ do
  start <- lit "syncon"
  ~(_, n) <- name <* lit ":"
  tyn <- tyName <* lit "="
  descrs <- Seq.fromList <$> some description <* lit "{" <* lit "builtin"
  end <- lit "}" -- TODO: parse body appropriately
  pure $ Syncon
    { s_name = n
    , s_syntaxType = tyn
    , s_syntaxDescription = SDSeq (foldMap range descrs) descrs
    , s_range = range start <> range end
    }

-- | A prefix syncon definition. The argument will be named 'SDRight'.
prefixDef :: Grammar r (Prod r Syncon)
prefixDef = syntaxDescription >>= \description -> rule . (<?> "prefix operator definition") $ do
  start <- lit "prefix"
  ~(_, n) <- name <* lit ":"
  ~(tyn_r, tyn) <- tyName <* lit "="
  descrs <- Seq.fromList <$> some description <* lit "{" <* lit "builtin"
  end <- lit "}" -- TODO: parse body appropriately
  pure $ Syncon
    { s_name = n
    , s_syntaxType = (tyn_r, tyn)
    , s_syntaxDescription = SDSeq
      (foldMap range descrs)
      (descrs Seq.|> SDNamed Nowhere SDRight (SDSyTy tyn_r tyn))
    , s_range = range start <> range end
    }

-- | A postfix syncon definition. The argument will be named 'SDLeft'.
postfixDef :: Grammar r (Prod r Syncon)
postfixDef = syntaxDescription >>= \description -> rule . (<?> "postfix operator definition") $ do
  start <- lit "postfix"
  ~(_, n) <- name <* lit ":"
  ~(tyn_r, tyn) <- tyName <* lit "="
  descrs <- Seq.fromList <$> some description <* lit "{" <* lit "builtin"
  end <- lit "}" -- TODO: parse body appropriately
  pure $ Syncon
    { s_name = n
    , s_syntaxType = (tyn_r, tyn)
    , s_syntaxDescription = SDSeq
      (foldMap range descrs)
      (SDNamed Nowhere SDLeft (SDSyTy tyn_r tyn) Seq.<| descrs)
    , s_range = range start <> range end
    }

-- | An infix syncon definition. The arguments will be named 'SDLeft' and 'SDRight', respectively.
infixDef :: Grammar r (Prod r (Syncon, Maybe Forbid))
infixDef = syntaxDescription >>= \description -> rule . (<?> "infix operator definition") $ do
  start <- lit "infix"
  ~(_, n) <- name <* lit ":"
  ~(tyn_r, tyn) <- tyName <* lit "="
  descrs <- Seq.fromList <$> many description <* lit "{"
  mForbid <- optional $ do
    start' <- lit "#assoc"
    sdname <- (SDRight <$ lit "left") -- NOTE: this inversion is intentional
              <|> (SDLeft <$ lit "right")
    end <- lit ";"
    pure $ \n' ->
      let r = range start' <> range end
      in Forbid r (r, n') (r, sdname) (r, n')
  end <- lit "builtin" *> lit "}"  -- TODO: body appropriately
  pure $ (, mForbid <*> pure n) $ Syncon
    { s_name = n
    , s_syntaxType = (tyn_r, tyn)
    , s_syntaxDescription = SDSeq
      (foldMap range descrs)
      (SDNamed Nowhere SDLeft (SDSyTy tyn_r tyn)
       Seq.<| (descrs
       Seq.|> SDNamed Nowhere SDRight (SDSyTy tyn_r tyn)))
    , s_range = range start <> range end
    }

-- |
-- == Syntax Descriptions

syntaxDescription :: Grammar r (Prod r SyntaxDescription)
syntaxDescription = mdo
  let sdsequence = do
        start <- lit "("
        descrs <- fmap Seq.fromList $ (:) <$> alted <*> some alted
        end <- lit ")"
        return $ SDSeq (range start <> range end) descrs
  let sdlit = uncurry SDToken <$> string
  let sdsyty = uncurry SDSyTy <$> tyName
  let atom = sdsequence <|> sdlit <|> sdsyty <|> (lit "(" *> alted <* lit ")")
  let named = do
        ~(r, Name n) <- name <* lit ":"
        inner <- atom
        return $ SDNamed (r <> range inner) (SDName n) inner
  let rep = ((,) <$> lit "*" <*> pure RepStar)
            <|> ((,) <$> lit "+" <*> pure RepPlus)
            <|> ((,) <$> lit "?" <*> pure RepQuestion)
  let repped = (mkRep <$> (named <|> atom) <*> rep) <|> named <|> atom
  let alts = mkAlt <$> some repped <*> some (lit "|" *> some repped)
  alted <- rule $ repped <|> alts <?> "syntax description"
  return repped
  where
    mkRep descr (tok, rep) = SDRep (range descr <> range tok) rep descr
    mkSeq [sd] = sd
    mkSeq sds = SDSeq (foldMap range sds) $ Seq.fromList sds
    mkAlt headAlt tailAlts =
      SDAlt (range headAlt' <> foldMap range tailAlts') $ Seq.fromList (headAlt' : tailAlts')
      where
        headAlt' = mkSeq headAlt
        tailAlts' = mkSeq <$> tailAlts

-- |
-- = Helpers

-- | Parse a 'TypeName', plus its 'Range'
name :: Prod r (Range, Name)
name = (<?> "name") . terminal $ \case
  OtherTok r _ NameTok n -> Just (r, Name n)
  _ -> Nothing

-- | Parse a 'TypeName', plus its 'Range'
tyName :: Prod r (Range, TypeName)
tyName = (<?> "type name") . terminal $ \case
  OtherTok r _ TypeNameTok n -> Just (r, TypeName n)
  _ -> Nothing

-- | Parse a string (well, 'Text'), plus its 'Range'. The string will have its escapes processed.
string :: Prod r (Range, Text)
string = (<?> "string") . terminal $ \case
  OtherTok r _ StringTok str -> Just (r, str & Text.tail & Text.init & Text.unpack & convert & Text.pack)
  _ -> Nothing
  where
    convert ('\\' : '\\' : rest) = '\\' : convert rest
    convert ('\\' : 'n' : rest) = '\n' : convert rest
    convert ('\\' : 't' : rest) = '\t' : convert rest
    convert ('\\' : '"' : rest) = '"' : convert rest
    convert (c : rest) = c : convert rest
    convert [] = ""

-- | Parse a literal
lit :: Text -> Prod r Tok
lit t = (<?> show t) . satisfy $ \case
  LitTok _ _ t' | t == t' -> True
  _ -> False