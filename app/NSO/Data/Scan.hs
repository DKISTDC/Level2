module NSO.Data.Scan where

import Data.Map qualified as M
import Data.String.Interpolate (i)
import Effectful
import Effectful.Error.Static
import Effectful.Rel8
import Effectful.Request
import Effectful.Time
import NSO.Data.Dataset
import NSO.Metadata
import NSO.Metadata.Types
import NSO.Prelude
import Text.Read (readMaybe)

-- scanDatasets :: (Time :> es, GraphQL :> es, Rel8 :> es, Error RequestError :> es) => Eff es [Dataset]
-- scanDatasets = do
--   now <- currentTime
--   ds <- fetchDatasets now
--   _ <- query () $ insertAll ds
--   pure ds

data SyncResult
  = New
  | Unchanged
  | Updated
  deriving (Eq)

data SyncResults = SyncResults
  { new :: [Dataset]
  , updated :: [Dataset]
  , unchanged :: [Dataset]
  }
  deriving (Eq)

scanDatasetInventory :: (GraphQL :> es, Error RequestError :> es, Time :> es) => Eff es [Dataset]
scanDatasetInventory = do
  now <- currentTime
  ads <- fetch @AllDatasets metadata ()
  let res = mapM (toDataset now) ads.datasetInventories
  either (throwError . ParseError) pure res

syncDatasets :: (GraphQL :> es, Error RequestError :> es, Rel8 :> es, Time :> es) => Eff es SyncResults
syncDatasets = do
  -- probably want to make a map of each and compare, no?
  scan <- scanDatasetInventory
  old <- indexed <$> queryLatest

  let res = syncResults old scan

  insertAll res.new

  updateOld $ map (.datasetId) res.updated
  insertAll res.updated

  pure res

syncResults :: Map (Id Dataset) Dataset -> [Dataset] -> SyncResults
syncResults old scan =
  let srs = map (syncResult old) scan
      res = zip srs scan
      new = results New res
      updated = results Updated res
      unchanged = results Unchanged res
   in SyncResults{new, updated, unchanged}
 where
  results r = map snd . filter ((== r) . fst)

syncResult :: Map (Id Dataset) Dataset -> Dataset -> SyncResult
syncResult old d = fromMaybe New $ do
  dold <- M.lookup d.datasetId old
  if d == dold{scanDate = d.scanDate}
    then pure Unchanged
    else pure Updated

toDataset :: UTCTime -> DatasetInventory -> Either String Dataset
toDataset scanDate d = do
  ins <- parseRead "Instrument" d.instrumentName
  pure
    $ Dataset
      { datasetId = Id d.datasetId
      , scanDate = scanDate
      , latest = True
      , observingProgramId = Id d.observingProgramExecutionId
      , instrumentProgramId = Id d.instrumentProgramExecutionId
      , boundingBox = boundingBoxNaN d.boundingBox
      , instrument = ins
      , stokesParameters = d.stokesParameters
      , createDate = d.createDate.utc
      , wavelengthMin = Wavelength d.wavelengthMin
      , wavelengthMax = Wavelength d.wavelengthMax
      , startTime = d.startTime.utc
      , endTime = d.endTime.utc
      , frameCount = fromIntegral d.frameCount
      , primaryExperimentId = Id d.primaryExperimentId
      , primaryProposalId = Id d.primaryProposalId
      , experimentDescription = d.experimentDescription
      , exposureTime = realToFrac d.exposureTime
      , inputDatasetObserveFramesPartId = Id . cs $ show d.inputDatasetObserveFramesPartId
      -- , -- WARNING: mocked fields
      --   health = JSONEncoded (Health d.frameCount 0 0 0)
      -- , gosStatus = JSONEncoded (GOSStatus d.frameCount 0 0 0 0)
      -- , aoLocked = fromIntegral d.frameCount
      }
 where
  parseRead :: (Read a) => Text -> Text -> Either String a
  parseRead expect input =
    maybe (Left [i|Invalid #{expect}: #{input}|]) Right $ readMaybe $ cs input

  boundingBoxNaN bb =
    if isCoordNaN bb.lowerLeft || isCoordNaN bb.upperRight
      then Nothing
      else Just bb

indexed :: [Dataset] -> Map (Id Dataset) Dataset
indexed = M.fromList . map (\d -> (d.datasetId, d))
