{-# LANGUAGE DerivingVia #-}

module NSO.Data.Dataset
  ( Dataset
  , Dataset' (..)
  , module NSO.Types.Dataset
  , Id (..)
  , Wavelength (..)
  , Nm
  , queryLatest
  , queryExperiment
  , queryProgram
  , insertAll
  , updateOld
  )
where

import Control.Monad (void)
import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int16)
import Effectful
import Effectful.Rel8
import NSO.Prelude
import NSO.Types.Common
import NSO.Types.Dataset
import NSO.Types.InstrumentProgram
import NSO.Types.Wavelength
import Rel8

type Dataset = Dataset' Identity
data Dataset' f = Dataset
  { datasetId :: Column f (Id Dataset)
  , scanDate :: Column f UTCTime
  , latest :: Column f Bool
  , observingProgramId :: Column f (Id ObservingProgram)
  , instrument :: Column f Instrument
  , instrumentProgramId :: Column f (Id InstrumentProgram)
  , stokesParameters :: Column f StokesParameters
  , createDate :: Column f UTCTime
  , wavelengthMin :: Column f (Wavelength Nm)
  , wavelengthMax :: Column f (Wavelength Nm)
  , startTime :: Column f UTCTime
  , endTime :: Column f UTCTime
  , frameCount :: Column f Int16
  , primaryExperimentId :: Column f (Id Experiment)
  , primaryProposalId :: Column f (Id Proposal)
  , experimentDescription :: Column f Text
  , exposureTime :: Column f Float
  , inputDatasetObserveFramesPartId :: Column f (Id ObserveFrames)
  , boundingBox :: Column f (Maybe BoundingBox)
  --   health :: Column f (JSONEncoded Health)
  -- , gosStatus :: Column f (JSONEncoded GOSStatus)
  -- , aoLocked :: Column f Int16
  }
  deriving (Generic, Rel8able)

deriving stock instance (f ~ Result) => Show (Dataset' f)
deriving stock instance (f ~ Result) => Eq (Dataset' f)

data Health = Health
  { good :: Int
  , bad :: Int
  , ill :: Int
  , unknown :: Int
  }
  deriving (Show, Generic, ToJSON, FromJSON)

data GOSStatus = GOSStatus
  { open :: Int
  , opening :: Int
  , closed :: Int
  , closing :: Int
  , undefined :: Int
  }
  deriving (Show, Generic, ToJSON, FromJSON)

datasets :: TableSchema (Dataset' Name)
datasets =
  TableSchema
    { name = "datasets"
    , schema = Nothing
    , columns =
        Dataset
          { datasetId = "dataset_id"
          , observingProgramId = "observing_program_id"
          , instrumentProgramId = "instrument_program_id"
          , instrument = "instrument"
          , scanDate = "scan_date"
          , stokesParameters = "stokes_parameters"
          , createDate = "create_date"
          , wavelengthMin = "wavelength_min"
          , wavelengthMax = "wavelength_max"
          , startTime = "start_time"
          , endTime = "end_time"
          , frameCount = "frame_count"
          , primaryExperimentId = "primary_experiment_id"
          , primaryProposalId = "primary_proposal_id"
          , inputDatasetObserveFramesPartId = "input_observe_frames_id"
          , experimentDescription = "experiment_description"
          , exposureTime = "exposure_time"
          , boundingBox = "bounding_box"
          , latest = "latest"
          -- , health = "health"
          -- , gosStatus = "gos_status"
          -- , aoLocked = "ao_locked"
          }
    }

queryLatest :: (Rel8 :> es) => Eff es [Dataset]
queryLatest = query () $ select $ do
  row <- each datasets
  where_ (row.latest ==. lit True)
  return row

queryExperiment :: (Rel8 :> es) => Id Experiment -> Eff es [Dataset]
queryExperiment eid = query () $ select $ do
  row <- each datasets
  where_ (row.primaryExperimentId ==. lit eid)
  return row

queryProgram :: (Rel8 :> es) => Id InstrumentProgram -> Eff es [Dataset]
queryProgram ip = query () $ select $ do
  row <- each datasets
  where_ (row.instrumentProgramId ==. lit ip)
  return row

insertAll :: (Rel8 :> es) => [Dataset] -> Eff es ()
insertAll ds =
  void
    $ query ()
    $ Rel8.insert
    $ Insert
      { into = datasets
      , rows = values $ fmap lit ds
      , onConflict = DoNothing
      , returning = NumberOfRowsAffected
      }

updateOld :: (Rel8 :> es) => [Id Dataset] -> Eff es ()
updateOld ids = do
  let ids' = fmap lit ids
  void
    $ query ()
    $ Rel8.update
    $ Update
      { target = datasets
      , set = \_ row -> row{latest = lit False}
      , updateWhere = \_ row -> row.datasetId `in_` ids'
      , from = pure ()
      , returning = NumberOfRowsAffected
      }
