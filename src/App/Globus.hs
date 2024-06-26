module App.Globus
  ( GlobusClient (..)
  , Globus
  , authUrl
  , accessToken
  , fileManagerUrl
  , transferStatus
  , Uri
  , Token
  , Task (..)
  , TaskStatus (..)
  , Tagged (..)
  , Token' (..)
  , Id' (..)
  , runGlobus
  , getAccessToken
  , saveAccessToken
  , clearAccessToken
  , taskPercentComplete
  , initDownload
  , initUpload
  , initScratchDataset
  , FileLimit (..)
  , TransferForm
  , UploadFiles (..)
  , DownloadFolder
  , Auth (..)
  , runAuth
  , requireLogin
  , runWithAccess
  , loginUrl
  , getRedirectUri
  , RedirectPath (..)
  , Timestamps
  , InvResults
  , InvProfile
  , OrigProfile
  ) where

import App.Scratch (InvProfile, InvResults, OrigProfile, Scratch, Timestamps)
import App.Scratch qualified as Scratch
import App.Types
import Data.Tagged
import Effectful
import Effectful.Dispatch.Dynamic
import Effectful.Globus
import Effectful.Globus qualified as Globus
import Effectful.Reader.Dynamic
import GHC.Generics
import NSO.Data.Inversions as Inversions
import NSO.Prelude
import NSO.Types.Common as App
import NSO.Types.Dataset
import Network.Globus.Transfer (taskPercentComplete)
import Network.HTTP.Types (QueryItem)
import Web.FormUrlEncoded (parseMaybe)
import Web.Hyperbole
import Web.Hyperbole.Effect (Host (..), Request (..))
import Web.Hyperbole.Forms
import Web.Hyperbole.Route (Route (..))
import Web.View as WebView


authUrl :: (Globus :> es) => Uri Redirect -> Eff es WebView.Url
authUrl red = do
  uri <- send $ AuthUrl red [TransferAll] (State "_")
  pure $ convertUrl uri
 where
  convertUrl :: Uri a -> WebView.Url
  convertUrl u =
    let Query ps = u.params
     in Url{scheme = scheme u.scheme, domain = u.domain, path = u.path, query = map query ps}
  scheme Https = "https://"
  scheme Http = "http://"
  query :: (Text, Maybe Text) -> QueryItem
  query (t, mt) = (cs t, cs <$> mt)


accessToken :: (Globus :> es) => Uri Redirect -> Token Exchange -> Eff es (Token Access)
accessToken red tok = do
  send $ AccessToken tok red


-- accessToken :: Globus -> Uri Redirect -> Token Exchange -> m TokenResponse
-- accessToken (Token cid) (Token sec) red (Token code) =

data FileLimit
  = Folders Int
  | Files Int


fileManagerUrl :: (Route r) => FileLimit -> r -> Text -> Request -> Url
fileManagerUrl lmt r lbl req =
  Url
    "https://"
    "app.globus.org"
    ["file-manager"]
    [ ("method", Just "POST")
    , ("action", Just $ cs (renderUrl submitUrl))
    , ("folderlimit", Just $ cs $ folderLimit lmt)
    , ("filelimit", Just $ cs $ fileLimit lmt)
    , ("cancelurl", Just $ cs (renderUrl currentUrl))
    , ("label", Just $ cs lbl)
    ]
 where
  -- <> "&origin_id=d26bd00b-62dc-40d2-9179-7aece2b8c437"
  -- <> "&origin_path=%2Fdata%2Fpid_1_118%2F"
  -- <> "&two_pane=true"
  fileLimit (Folders _) = "0"
  fileLimit (Files n) = show n

  folderLimit (Folders n) = show n
  folderLimit (Files _) = "0"

  serverUrl :: [Text] -> Url
  serverUrl p = Url "https://" (cs req.host.text) p []

  currentUrl :: Url
  currentUrl = serverUrl req.path

  submitUrl :: Url
  submitUrl =
    serverUrl $ routePath r


data TransferForm = TransferForm
  { label :: Field Text
  , -- , endpoint :: Field Text
    path :: Field (Path' Dir TransferForm)
  , endpoint_id :: Field Text
  }
  deriving (Generic, Form)


data DownloadFolder = DownloadFolder
  { folder :: Maybe (Path' Dir DownloadFolder)
  }
  deriving (Generic)
instance Form DownloadFolder where
  formParse f = do
    DownloadFolder <$> parseMaybe "folder[0]" f


data UploadFiles t = UploadFiles
  { invProfile :: Path' t InvProfile
  , invResults :: Path' t InvResults
  , origProfile :: Path' t OrigProfile
  , timestamps :: Path' t Timestamps
  }
  deriving (Generic, Show)
instance Form (UploadFiles Filename) where
  formParse f = do
    fs <- multi "file"
    invProfile <- findFile Scratch.fileInvProfile fs
    invResults <- findFile Scratch.fileInvResults fs
    origProfile <- findFile Scratch.fileOrigProfile fs
    timestamps <- findFile Scratch.fileTimestamps fs
    pure UploadFiles{invResults, invProfile, origProfile, timestamps}
   where
    sub :: Text -> Int -> Text
    sub t n = t <> "[" <> cs (show n) <> "]"
    multi t = do
      sub0 <- parseMaybe (sub t 0) f
      sub1 <- parseMaybe (sub t 1) f
      sub2 <- parseMaybe (sub t 2) f
      pure $ catMaybes [sub0, sub1, sub2]

    findFile :: Path' Filename a -> [FilePath] -> Either Text (Path' Filename a)
    findFile (Path file) fs = do
      if file `elem` fs
        then pure $ Path file
        else Left $ "Missing required file: " <> cs file


transferStatus :: (Reader (Token Access) :> es, Globus :> es) => App.Id Task -> Eff es Task
transferStatus (Id ti) = do
  acc <- ask
  send $ StatusTask acc (Tagged ti)


-- initTransfer :: (Hyperbole :> es, Globus :> es, Auth :> es) => (Globus.Id Submission -> TransferRequest) -> Eff es (Id Task)
-- initTransfer toRequest = do

initTransfer :: (Globus :> es, Reader (Token Access) :> es) => (Globus.Id Submission -> TransferRequest) -> Eff es (App.Id Task)
initTransfer toRequest = do
  acc <- ask
  sub <- send $ Globus.SubmissionId acc
  res <- send $ Globus.Transfer acc $ toRequest sub
  pure $ Id res.task_id.unTagged


initUpload
  :: (Hyperbole :> es, Globus :> es, Auth :> es, Reader Scratch :> es)
  => TransferForm
  -> UploadFiles Filename
  -> App.Id Inversion
  -> Eff es (App.Id Task)
initUpload tform up ii = do
  scratch <- ask @Scratch
  requireLogin $ initTransfer (transferRequest scratch)
 where
  transferRequest :: Scratch -> Globus.Id Submission -> TransferRequest
  transferRequest scratch submission_id =
    TransferRequest
      { data_type = DataType
      , submission_id
      , label = Just tform.label.value
      , source_endpoint = Tagged tform.endpoint_id.value
      , destination_endpoint = scratch.collection
      , data_ = [transferItem up.invResults, transferItem up.invProfile, transferItem up.origProfile]
      , sync_level = SyncChecksum
      , store_base_path_info = True
      }
   where
    transferItem :: Path' Filename a -> TransferItem
    transferItem f =
      TransferItem
        { data_type = DataType
        , source_path = (source tform.path.value f).filePath
        , destination_path = (dest f).filePath
        , recursive = False
        }

    dest :: Path' Filename a -> Path' File a
    dest fn = Scratch.inversion ii </> fn

    source :: Path' Dir TransferForm -> Path' Filename a -> Path' File a
    source t fn = t </> fn


initDownload :: (Globus :> es, Reader (Token Access) :> es) => TransferForm -> DownloadFolder -> [Dataset] -> Eff es (App.Id Task)
initDownload tform df ds = do
  initTransfer downloadTransferRequest
 where
  downloadTransferRequest :: Globus.Id Submission -> TransferRequest
  downloadTransferRequest submission_id =
    TransferRequest
      { data_type = DataType
      , submission_id
      , label = Just tform.label.value
      , source_endpoint = dkistEndpoint
      , destination_endpoint = Tagged tform.endpoint_id.value
      , data_ = map (\d -> datasetTransferItem (destinationPath d) d) ds
      , sync_level = SyncChecksum
      , store_base_path_info = True
      }
   where
    destinationFolder :: Path' Dir TransferForm
    destinationFolder =
      -- If they didn't select a folder, use the current folder
      case df.folder of
        Just f -> tform.path.value </> f
        Nothing -> tform.path.value

    destinationPath :: Dataset -> Path' Dir Dataset
    destinationPath d =
      destinationFolder </> Path (cs d.instrumentProgramId.fromId) </> Path (cs d.datasetId.fromId)


initScratchDataset :: (Globus :> es, Reader (Token Access) :> es, Reader Scratch :> es) => Dataset -> Eff es (App.Id Task, Path' Dir Dataset)
initScratchDataset d = do
  scratch <- ask
  t <- initTransfer (transfer scratch)
  pure (t, Scratch.dataset d)
 where
  transfer :: Scratch -> Globus.Id Submission -> TransferRequest
  transfer scratch submission_id =
    TransferRequest
      { data_type = DataType
      , submission_id
      , label = Just $ "Dataset " <> d.datasetId.fromId
      , source_endpoint = dkistEndpoint
      , destination_endpoint = scratch.collection
      , data_ = [datasetTransferItem (Scratch.dataset d) d]
      , sync_level = SyncChecksum
      , store_base_path_info = True
      }


dkistEndpoint :: Globus.Id Collection
dkistEndpoint = Tagged "d26bd00b-62dc-40d2-9179-7aece2b8c437"


datasetTransferItem :: Path' Dir Dataset -> Dataset -> TransferItem
datasetTransferItem dest d =
  TransferItem
    { data_type = DataType
    , source_path = datasetSourcePath.filePath
    , destination_path = dest.filePath
    , recursive = True
    }
 where
  datasetSourcePath :: Path' DKIST Dataset
  datasetSourcePath = Path "data" </> Path (cs d.primaryProposalId.fromId) </> Path (cs d.datasetId.fromId)


-- Authentication!
data Auth :: Effect where
  LoginUrl :: RedirectPath -> Auth m Url
  RedirectUri :: RedirectPath -> Auth m (Uri Globus.Redirect)


type instance DispatchOf Auth = 'Dynamic


runAuth
  :: (Globus :> es, Route r)
  => AppDomain
  -> r
  -> Eff (Auth : es) a
  -> Eff es a
runAuth dom r = interpret $ \_ -> \case
  LoginUrl rp -> do
    authUrl $ redirectUri dom r rp
  -- \$ redirectRoute rp
  RedirectUri rp -> do
    pure $ redirectUri dom r rp


-- \$ redirectRoute rp

-- WARNING:  until we update the globus app, it only allows /redirect, no query, no nothing
redirectUri :: (Route r) => AppDomain -> r -> RedirectPath -> Uri Globus.Redirect
redirectUri dom r (RedirectPath _) = do
  -- let path = T.intercalate "/" rp
  Uri Https (cs dom.unTagged) (routePath r) (Query []) -- (Query [("path", Just path)])


getRedirectUri :: (Hyperbole :> es, Auth :> es) => Eff es (Uri Globus.Redirect)
getRedirectUri = do
  rp <- redirectPath
  send $ RedirectUri rp


expectAuth :: (Hyperbole :> es, Auth :> es) => Maybe a -> Eff es a
expectAuth Nothing = do
  u <- loginUrl
  redirect u
expectAuth (Just a) = pure a


loginUrl :: (Hyperbole :> es, Auth :> es) => Eff es Url
loginUrl = do
  rp <- redirectPath
  send $ LoginUrl rp


redirectPath :: (Hyperbole :> es) => Eff es RedirectPath
redirectPath = do
  r <- request
  pure $ RedirectPath r.path


getAccessToken :: (Hyperbole :> es, Auth :> es) => Eff es (Maybe (Token Access))
getAccessToken = do
  fmap Tagged <$> session "globus"


saveAccessToken :: (Hyperbole :> es) => Token Access -> Eff es ()
saveAccessToken (Tagged acc) = setSession "globus" acc


clearAccessToken :: (Hyperbole :> es) => Eff es ()
clearAccessToken = clearSession "globus"


runWithAccess :: Token Access -> Eff (Reader (Token Access) : es) a -> Eff es a
runWithAccess = runReader


requireLogin :: (Hyperbole :> es, Auth :> es) => Eff (Reader (Token Access) : es) a -> Eff es a
requireLogin eff = do
  acc <- getAccessToken >>= expectAuth
  runWithAccess acc eff


newtype RedirectPath = RedirectPath [Segment]
  deriving (Show, Eq)


instance Route RedirectPath where
  defRoute = RedirectPath []
  routePath (RedirectPath ss) = ss
  matchRoute ss = Just $ RedirectPath ss


data DKIST
