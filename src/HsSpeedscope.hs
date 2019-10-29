{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module HsSpeedscope where


import Data.Aeson
import GHC.RTS.Events

import Data.Word
import Data.Text (Text)
import Data.Foldable
import qualified Data.Vector.Unboxed as V
import System.Environment
import Data.Maybe
import Data.List.Extra
import Control.Monad
import Data.Char

import Data.Version
import Text.ParserCombinators.ReadP
import qualified Paths_hs_speedscope as Paths

entry :: IO ()
entry = do
  fps <- getArgs
  case fps of
    [fp] -> do
      el <- either error id <$> readEventLogFromFile fp
      encodeFile (fp ++ ".json") (convertToSpeedscope el)
    _ -> error "Usage: hs-speedscope program.eventlog"

convertToSpeedscope :: EventLog -> Value
convertToSpeedscope (EventLog h (Data es)) =
  case rts_version of
    Just (version, _) | version <= makeVersion [8,9,0]  ->
      error ("Eventlog is from ghc-" ++ showVersion version ++ " hs-speedscope only works with GHC 8.10 or later")
    _ -> object [ "version" .= ("0.0.1" :: String)
                , "$schema" .= ("https://www.speedscope.app/file-format-schema.json" :: String)
                , "shared" .= object [ "frames" .= ccs_json ]
                , "profiles" .= map (mkProfile name interval) caps
                , "name" .= name
                , "activeProfileIndex" .= (0 :: Int)
                , "exporter" .= version_string
                ]
  where
    (EL (fromMaybe "" -> name) rts_version (fromMaybe 1 -> interval) frames samples) =
      foldr processEvents initEL es

    initEL = EL Nothing Nothing Nothing [] []

    version_string :: String
    version_string = "hs-speedscope@" ++ showVersion Paths.version

    -- Drop 7 events for built in cost centres like GC, IDLE etc

    ccs_json :: [Value]
    ccs_json = map mkFrame (reverse (drop 7 frames))

    num_frames = length ccs_json


    caps :: [(Capset, [[Int]])]
    caps = groupSort $ mapMaybe mkSample samples

    mkFrame :: CostCentre -> Value
    mkFrame (CostCentre n l m s) = object [ "name" .= l, "file" .= s ]

    mkSample :: Sample -> Maybe (Capset, [Int])
    -- Filter out system frames
    mkSample (Sample ti [k]) | fromIntegral k >= num_frames = Nothing
    mkSample (Sample ti ccs) = Just $ (ti, reverse $ map (subtract 1 . fromIntegral) ccs)


    processEvents :: Event -> EL -> EL
    processEvents (Event t ei c) el =
      case ei of
        ProgramArgs _ (prog_name: _args) -> el { prog_name = Just prog_name }
        RtsIdentifier _ rts_ident -> el { rts_version = parseIdent rts_ident }
        ProfBegin interval -> el { prof_interval = Just interval }
        HeapProfCostCentre n l m s _ -> el { cost_centres = CostCentre n l m s : cost_centres el }
        ProfSampleCostCentre t _ _ st -> el { el_samples = Sample t (V.toList st) : el_samples el }
        _ -> el

mkProfile :: String -> Word64 -> (Capset, [[Int]]) -> Value
mkProfile prog_name interval (n, samples) =
  object [ "type" .= ("sampled" :: String)
         , "unit" .= ("nanoseconds" :: String)
         , "name" .= prog_name
         , "startValue" .= (0 :: Int)
         , "endValue" .= (length samples :: Int)
         , "samples" .= samples
         , "weights" .= sample_weights ]
  where
    sample_weights :: [Word64]
    sample_weights = replicate (length samples) interval

parseIdent :: String -> Maybe (Version, String)
parseIdent s = listToMaybe $ flip readP_to_S s $ do
  void $ string "GHC-"
  [v1, v2, v3] <- replicateM 3 (intP <* optional (char '.'))
  skipSpaces
  return (makeVersion [v1,v2,v3])
  where
    intP = do
      x <- munch1 isDigit
      return $ read x

data EL = EL {
    prog_name :: Maybe String
    , rts_version :: Maybe (Version, String)
    , prof_interval :: Maybe Word64
    , cost_centres :: [CostCentre]
    , el_samples :: [Sample]
}

data CostCentre = CostCentre Word32 Text Text Text

data Sample = Sample Capset [Word32]