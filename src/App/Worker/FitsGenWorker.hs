{-# LANGUAGE RecordWildCards #-}

module App.Worker.FitsGenWorker
  ( workTask
  , GenerateError
  , GenInversion (..)
  , GenStatus (..)
  , GenInvStep (..)
  , Tasks
  , GenFrame (..)
  , workFrame
  ) where

import App.Effect.Scratch as Scratch
import App.Globus (Globus, Token, Token' (Access))
import App.Globus qualified as Globus
import Control.Monad.Catch (catch)
import Control.Monad.Loops
import Data.Diverse.Many
import Effectful
import Effectful.Concurrent
import Effectful.Dispatch.Dynamic
import Effectful.Error.Static
import Effectful.FileSystem
import Effectful.GenRandom
import Effectful.Log
import Effectful.Reader.Dynamic
import Effectful.Tasks
import Effectful.Time
import NSO.Data.Datasets
import NSO.Data.Inversions as Inversions
import NSO.Fits.Generate as Gen
import NSO.Fits.Generate.Error
import NSO.Fits.Generate.FetchL1 as Fetch (canonicalL1Frames, fetchCanonicalDataset, readTimestamps)
import NSO.Fits.Generate.Profile (Fit, Original, ProfileFrames (..), WavProfiles)
import NSO.Prelude
import NSO.Types.InstrumentProgram


data GenInversion = GenInversion {proposalId :: Id Proposal, inversionId :: Id Inversion}
  deriving (Eq)


instance Show GenInversion where
  show g = "GenInversion " <> show g.proposalId <> " " <> show g.inversionId


instance WorkerTask GenInversion where
  type Status GenInversion = GenStatus
  idle = GenStatus GenWaiting 0 0


data GenInvStep
  = GenWaiting
  | GenStarted
  | GenTransferring
  | GenCreating
  deriving (Show, Eq, Ord)


data GenStatus = GenStatus
  { step :: GenInvStep
  , totalFrames :: Int
  , complete :: Int
  }
  deriving (Eq, Ord)


instance Show GenStatus where
  show g = "GenStatus " <> show g.step <> " " <> show g.totalFrames <> " " <> show g.complete


data GenFrame = GenFrame
  { parent :: GenInversion
  , wavOrig :: WavProfiles Original
  , wavFit :: WavProfiles Fit
  , frame :: GenerateFrame
  , index :: Int
  }


instance Eq GenFrame where
  f1 == f2 =
    f1.parent == f2.parent
      && f1.index == f2.index


instance WorkerTask GenFrame where
  type Status GenFrame = ()
  idle = ()


-- DOING: parallelize!
-- DONE: progress bar

workTask
  :: forall es
   . ( Reader (Token Access) :> es
     , Globus :> es
     , FileSystem :> es
     , Datasets :> es
     , Inversions :> es
     , Time :> es
     , Scratch :> es
     , Log :> es
     , Concurrent :> es
     , Tasks GenInversion :> es
     , Tasks GenFrame :> es
     , GenRandom :> es
     )
  => GenInversion
  -> Eff es ()
workTask t = do
  res <- runErrorNoCallStack $ catch workWithError onCaughtError
  either failed pure res
 where
  onCaughtError :: IOError -> Eff (Error GenerateError : es) a
  onCaughtError e = do
    throwError $ GenIOError e

  workWithError = do
    log Debug "START"

    send $ TaskSetStatus t $ GenStatus GenStarted 0 0

    inv <- loadInversion t.inversionId
    (taskId, frameDir) <- startTransferIfNeeded inv.programId inv.step
    log Debug $ dump "Task" taskId
    send $ Inversions.SetGenerating t.inversionId taskId frameDir.filePath
    send $ TaskSetStatus t $ GenStatus GenTransferring 0 0

    log Debug " - waiting..."
    untilM_ delay (isTransferComplete taskId)
    send $ Inversions.SetGenTransferred t.inversionId

    log Debug " - done, getting frames..."
    let u = Scratch.inversionUploads $ Scratch.inversion t.proposalId t.inversionId
    log Debug $ dump "InvResults" u.invResults
    log Debug $ dump "InvProfile" u.invProfile
    log Debug $ dump "OrigProfile" u.origProfile
    log Debug $ dump "Timestamps" u.timestamps

    qfs <- Gen.readQuantitiesFrames u.invResults
    pfs <- Gen.readFitProfileFrames u.invProfile
    pos <- Gen.readOrigProfileFrames u.origProfile
    ts <- Fetch.readTimestamps u.timestamps
    log Debug $ dump "TS" (length ts)
    l1 <- Fetch.canonicalL1Frames frameDir ts
    log Debug $ dump "Frames" (length qfs, length pfs.frames, length pos.frames, length l1)
    gfs <- collateFrames qfs pfs.frames pos.frames l1
    let totalFrames = length gfs

    log Debug $ dump "Ready to Build!" (length gfs)
    send $ TaskSetStatus t $ GenStatus GenCreating 0 totalFrames
    let gfts = zipWith (GenFrame t pos.wavProfiles pfs.wavProfiles) gfs [0 ..]
    send $ TasksAdd gfts

    log Debug " - done, waiting for individual jobs"

    -- we wait to wait for the children
    -- maybe.... we want to use a pooled X whatever instead of more jobs..
  -- TODO: need to mark a status no... otherwise it gets picked up again by the puppetmaster...

  failed :: GenerateError -> Eff es ()
  failed err = do
    send $ Inversions.SetError t.inversionId (cs $ show err)


workFrame
  :: (Tasks GenInversion :> es, Time :> es, Error GenerateError :> es, GenRandom :> es, Log :> es, Scratch :> es)
  => GenFrame
  -> Eff es ()
workFrame t = do
  send $ TaskModStatus @GenInversion t.parent updateNumFrame
  now <- currentTime
  (fits, dateBeg) <- Gen.generateL2Fits now t.parent.inversionId t.wavOrig t.wavFit t.frame
  log Debug $ dump "write" dateBeg
  Gen.writeL2Frame t.parent.proposalId t.parent.inversionId fits dateBeg
  pure ()
 where
  updateNumFrame :: GenStatus -> GenStatus
  updateNumFrame GenStatus{..} = GenStatus{complete = complete + 1, ..}


startTransferIfNeeded :: (Error GenerateError :> es, Reader (Token Access) :> es, Scratch :> es, Datasets :> es, Globus :> es) => Id InstrumentProgram -> InversionStep -> Eff es (Id Globus.Task, Path' Dir Dataset)
startTransferIfNeeded ip = \case
  StepGenTransfer info -> do
    let t = grab @GenTransfer info
    pure (t.taskId, Path t.frameDir)
  StepGenerating info -> do
    let g = grab @GenTransfer info
    pure (g.taskId, Path g.frameDir)
  _ ->
    Fetch.fetchCanonicalDataset ip


isTransferComplete :: (Log :> es, Globus :> es, Reader (Token Access) :> es, Error GenerateError :> es) => Id Globus.Task -> Eff es Bool
isTransferComplete it = do
  task <- Globus.transferStatus it
  case task.status of
    Globus.Succeeded -> pure True
    Globus.Failed -> throwError $ L1TransferFailed it
    _ -> do
      log Debug $ dump "Transfer" $ Globus.taskPercentComplete task
      pure False


loadInversion :: (Inversions :> es, Error GenerateError :> es) => Id Inversion -> Eff es Inversion
loadInversion ii = do
  is <- send $ Inversions.ById ii
  case is of
    [inv] -> pure inv
    _ -> throwError $ MissingInversion ii


delay :: (Concurrent :> es) => Eff es ()
delay = threadDelay $ 2 * 1000 * 1000
