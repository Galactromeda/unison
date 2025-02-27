{- ORMOLU_DISABLE -} -- Remove this when the file is ready to be auto-formatted
{-# Language OverloadedStrings #-}

module Unison.PrettyPrintEnvDecl.Names where

import Unison.NamesWithHistory (NamesWithHistory)
import Unison.PrettyPrintEnvDecl (PrettyPrintEnvDecl (PrettyPrintEnvDecl))
import Unison.PrettyPrintEnv.Names (fromNames, fromSuffixNames)

fromNamesDecl :: Int -> NamesWithHistory -> PrettyPrintEnvDecl
fromNamesDecl hashLength names =
  PrettyPrintEnvDecl (fromNames hashLength names) (fromSuffixNames hashLength names)
