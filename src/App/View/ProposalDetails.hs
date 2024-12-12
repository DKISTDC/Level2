module App.View.ProposalDetails
  ( viewExperimentDescription
  , viewProgramRow
  , viewCriteria
  , viewProgramSummary
  ) where

import App.Colors
import App.Route as Route
import App.Style qualified as Style
import App.View.Common (showTimestamp)
import App.View.Common as View (hr)
import App.View.DataRow (dataCell, tagCell)
import App.View.DatasetsTable as DatasetsTable
import App.View.Icons as Icons
import App.View.Inversions (inversionStepTag)
import Data.Grouped
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as Text
import NSO.Data.Datasets
import NSO.Data.Programs
import NSO.Data.Qualify
import NSO.Prelude
import Web.Hyperbole


viewExperimentDescription :: Text -> View c ()
viewExperimentDescription t = do
  let ps = Text.splitOn "\\n" t
  col (gap 10) $ do
    mapM_ (el_ . text) ps


viewProgramRow :: UTCTime -> InstrumentProgramStatus -> View c ()
viewProgramRow now ips = row (gap 10 . textAlign Center . grow) $ do
  let ip = ips.program :: InstrumentProgram
  statusTag ips.status

  -- el dataCell $ text $ showDate ip.startTime
  -- el dataCell $ text $ showDate ip.startTime
  el dataCell $ text $ cs $ show ip.instrument
  -- not worth showing Stokes in the row. They seem to be present for all VISP
  -- el dataCell $ text $ cs $ show ip.stokesParameters

  code (cell . color Secondary) $ text $ cs $ showTimestamp ip.startTime

  row (dataCell . gap 5 . fontSize 14) $ do
    maybe none embargoTag ip.embargo
    if ip.onDisk then diskTag else none
    mapM_ lineTag ip.spectralLines
    mapM_ midTag $ sortOn id ip.otherWavelengths

  space

  code (cell . color Secondary) $ text ips.program.programId.fromId
 where
  cell = dataCell . fontSize 14 . pad 2

  lineTag :: SpectralLine -> View c ()
  lineTag s = tag "pre" (dataTag . Style.tagOutline (light Secondary)) $ text $ cs $ show s

  diskTag = el (dataTag . Style.tagOutline (light Primary)) "On Disk"

  embargoTag utc =
    if utc > now
      then el (dataTag . Style.tagOutline (dark Warning)) "Embargoed"
      else none

  midTag mid =
    code (pad 2 . color (light Secondary)) $ text $ cs (show (round mid :: Integer) <> "nm")

  dataTag :: Mod
  dataTag = pad (XY 6 1)

  code = tag "pre"


statusTag :: ProgramStatus -> View c ()
statusTag = \case
  StatusInvalid -> el (tagCell . color (light Secondary)) $ text "-"
  StatusQualified -> el (stat Primary) $ text "Qualified"
  StatusInversion step -> inversionStepTag step
  StatusError _ -> el (stat Danger) $ text "Error"
 where
  stat c = tagCell . Style.tag c


-- statusTag Queued = el (dataCell . bg Warning) $ text "Queued"
-- statusTag Inverted = el (dataCell . bg SecondaryLight) $ text "Complete"

viewCriteria :: InstrumentProgramStatus -> Grouped InstrumentProgram Dataset -> View c ()
viewCriteria ip gd = do
  col (pad 8) $ do
    case ip.program.instrument of
      VISP -> vispCriteria gd ip.program.spectralLines
      VBI -> vbiCriteria
      CRYO_NIRSP -> cryoCriteria
 where
  vispCriteria :: Grouped InstrumentProgram Dataset -> [SpectralLine] -> View c ()
  vispCriteria ds sls = do
    el (bold . height criteriaRowHeight) "VISP Criteria"
    criteria "Stokes IQUV" $ qualifyStokes ds
    criteria "On Disk" $ qualifyOnDisk ds
    criteria "Spectra: FeI" $ qualifyLine FeI sls
    criteria "Spectra: CaII 854" $ qualifyLine (CaII CaII_854) sls
    criteria "Health" $ qualifyHealth ds
    criteria "GOS Status" $ qualifyGOS ds
    criteria "AO Lock" $ qualifyAO ds

  vbiCriteria = do
    el bold "VBI Criteria"
    criteria "Not Supported" False

  cryoCriteria = do
    el bold "CRYO NIRSP Criteria"
    criteria "Not Supported" False

  criteriaRowHeight :: Length
  criteriaRowHeight = 32

  criteria :: Text -> Bool -> View c ()
  criteria msg b =
    row (gap 6 . height criteriaRowHeight . color (if b then Success else Danger)) $ do
      el (pad 4) checkmark
      el (pad 4) (text msg)
   where
    checkmark =
      el (width 24 . height 24) $
        if b
          then Icons.checkCircle
          else Icons.xMark


-- viewProgramSummary :: UTCTime -> WithDatasets -> View c ()
-- viewProgramSummary now wdp = do
--   col (gap 10) $ do
--     col (bg White . gap 10 . pad 10) $ do
--       route (Proposal wdp.program.proposalId $ Program wdp.program.programId) flexRow $ do
--         viewProgramRow now wdp.program
--       row (gap 10) $ do
--         route (Proposal wdp.program.proposalId $ Program wdp.program.programId) Style.link $ do
--           text wdp.program.programId.fromId
--         space
--         forM_ wdp.datasets.items $ \d -> do
--           route (Dataset d.datasetId) Style.link $ do
--             text d.datasetId.fromId
--

viewProgramSummary :: (HyperViewHandled ProgramDatasets c) => UTCTime -> ProgramFamily -> View c ()
viewProgramSummary now pf = do
  let ds = pf.datasets.items
  let p = pf.program :: InstrumentProgramStatus
  col Style.card $ do
    route (Proposal p.program.proposalId $ Program p.program.programId) (Style.cardHeader Secondary) $ text $ "Instrument Program - " <> p.program.programId.fromId
    col (gap 15 . pad 15) $ do
      viewProgramDetails p now (NE.filter (.latest) ds)
      hyper (ProgramDatasets p.program.programId) $ DatasetsTable.datasetsTable ByLatest (NE.toList ds)


viewProgramDetails :: InstrumentProgramStatus -> UTCTime -> [Dataset] -> View c ()
viewProgramDetails _ _ [] = none
viewProgramDetails ips now (d : ds) = do
  let p = ips.program :: InstrumentProgram
  let gd = Grouped (d :| ds)

  row (textAlign Center) $ do
    route (Proposal p.proposalId $ Program p.programId) grow $ do
      viewProgramRow now ips

  View.hr (color Gray)

  viewCriteria ips gd
