{-# LANGUAGE UndecidableInstances #-}

module NSO.Fits.Generate where

import Control.Monad.Catch (Exception, MonadThrow, throwM)
import Data.ByteString qualified as BS
import Data.Massiv.Array
import NSO.Fits.Generate.DataHDU (quantitiesHDUs)
import NSO.Fits.Generate.Frames
import NSO.Fits.Generate.Headers
import NSO.Fits.Generate.Keywords
import NSO.Fits.Generate.Types
import NSO.Prelude
import NSO.Types.Common (Id (..))
import Telescope.Fits
import Telescope.Fits.Types (HeaderRecord (..))


-- TODO: WCS (CRPIX, CRVAL, CUNIT, CTYPE, etc)

------------------------------------------------------------------------------

testInput :: FilePath
testInput = "/Users/seanhess/Data/scan1807/inv_res_mod.fits"


level1Input :: FilePath
level1Input = "/Users/seanhess/Data/pid_2_114/ADDMM/VISP_2023_10_16T23_55_59_513_00589600_I_ADDMM_L1.fits"


test :: IO ()
test = do
  putStrLn "TEST"
  (f : _) <- readQuantitiesFrames testInput
  i1 <- readLevel1 level1Input

  putStrLn "\nCHECK OPTICAL DEPTH"
  print $ size f.opticalDepth.array
  print $ f.opticalDepth.array !> 0
  print $ f.opticalDepth.array !> 20
  print $ f.opticalDepth.array !> 40

  let hdus = quantitiesHDUs i1 f
  let (od : _) = hdus

  putStrLn "\nCHECK HDUS"
  print od.header
  print od.dataArray.axes

  -- print $ size f.temperature.array

  -- print $ f.temperature.array !> 1

  -- let dat = encodeArray f.opticalDepth.array
  -- print dat.axes
  -- print dat.bitpix
  -- print $ BS.length dat.rawData
  --
  fits <- quantitiesFits i1 f
  print $ length fits.extensions

  --
  -- let (Image i : _) = fits.extensions
  -- -- print $ BS.length i.dataArray.rawData
  --
  -- print fits.primaryHDU.dataArray.rawData

  let out = encode fits
  BS.writeFile "/Users/seanhess/code/notebooks/data/out.fits" out


readLevel1 :: (MonadThrow m, MonadIO m) => FilePath -> m ImageHDU
readLevel1 fp = do
  inp <- liftIO $ BS.readFile fp
  fits <- decode inp
  case fits.extensions of
    [Image i] -> pure i
    _ -> throwM $ MissingL1HDU fp


-- TODO: add primary HDU somewhere ...
quantitiesFits :: (MonadThrow m) => ImageHDU -> Quantities [SlitX, Depth] -> m Fits
quantitiesFits l1 q = do
  prim <- primaryHDU l1
  pure $ Fits prim $ fmap Image $ quantitiesHDUs l1 q


-- What is supposed to go in here?
primaryHDU :: (MonadThrow m) => ImageHDU -> m PrimaryHDU
primaryHDU l1 = do
  ph <- primaryHeader l1.header (Id "unique id")
  pure $ PrimaryHDU (Header (keywords ph)) emptyDataArray
 where
  keywords p = fmap Keyword $ headerKeywords @PrimaryHeader p


data FitsGenError
  = MissingL1 String
  deriving (Show, Exception)
