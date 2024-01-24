module App.Page.Experiment where

import App.Colors
import App.Route
import App.Style qualified as Style
import App.View.DatasetsTable as DatasetsTable
import App.View.InstrumentProgramSummary as InstrumentProgramSummary
import Data.Grouped as G
import Effectful.Rel8
import Effectful.Time
import NSO.Data.Datasets
import NSO.Data.Programs as Programs
import NSO.Data.Provenance as Provenance
import NSO.Prelude
import NSO.Types.InstrumentProgram
import Web.Hyperbole


page :: (Hyperbole :> es, Time :> es, Rel8 :> es) => Id Experiment -> Page es ()
page eid = do
  hyper DatasetsTable.actionSort

  load $ do
    ds <- queryExperiment eid
    pv <- loadAllProvenance
    now <- currentTime
    let pwds = Programs.fromDatasets pv ds

    pure $ appLayout Experiments $ do
      col Style.page $ do
        el Style.header $ do
          text "Experiment  "
          text eid.fromId

        viewPrograms now pwds


-- DatasetsTable.datasetsTable ds

-- each InstrumentProgram MUST have datasets
viewPrograms :: UTCTime -> [WithDatasets] -> View c ()
viewPrograms _ [] = el_ "Not Found"
viewPrograms now (p : ps) = do
  let wds = Grouped (p :| ps) :: Grouped Experiment WithDatasets
  viewExperiment now wds


viewExperiment :: UTCTime -> Grouped Experiment WithDatasets -> View c ()
viewExperiment now gx = do
  let wd = sample gx
  el_ $ text wd.program.experimentDescription
  mapM_ (programSummary now) gx


programSummary :: UTCTime -> WithDatasets -> View c ()
programSummary now wdp = do
  col (gap 10) $ do
    el Style.subheader $ do
      text "Instrument Program "
      link (Program wdp.program.programId) Style.link $ do
        text wdp.program.programId.fromId

    col (bg White . gap 10 . pad 10) $ do
      row id $ do
        InstrumentProgramSummary.viewRow now wdp.program
      -- space
      -- link (Program wdp.program.programId) (color Primary . bold) $ do
      --   text wdp.program.programId.fromId
      -- :: Grouped InstrumentProgram Dataset
      InstrumentProgramSummary.viewCriteria wdp.program wdp.datasets
      viewId (ProgramDatasets wdp.program.programId) $ do
        DatasetsTable.datasetsTable UpdateDate $ G.toList wdp.datasets
