module NSO.Image.Headers.Parse where

import Control.Monad.Catch (Exception)
import Data.Text (unpack)
import Effectful
import Effectful.Error.Static
import NSO.Image.Headers.Types
import NSO.Prelude
import Telescope.Fits as Fits
import Telescope.Fits.Header (KeywordRecord, getKeywords, toText)


lookupKey :: (Monad m) => Text -> (Value -> Maybe a) -> Header -> m (Maybe a)
lookupKey k fromValue h =
  let mk = Fits.lookup k h
   in case fromValue =<< mk of
        Nothing -> pure Nothing
        Just t -> pure (Just t)


requireKey :: (Error ParseError :> es) => Text -> (Value -> Maybe a) -> Header -> Eff es a
requireKey k fromValue h =
  let mk = Fits.lookup k h
   in case fromValue =<< mk of
        Nothing -> throwError (MissingKey (unpack k))
        Just t -> pure t


findKey :: (KeywordRecord -> Maybe a) -> Header -> Maybe a
findKey p h = do
  listToMaybe $ mapMaybe p $ getKeywords h


toDate :: Value -> Maybe DateTime
toDate v = DateTime <$> toText v


data ParseError
  = MissingKey String
  deriving (Show, Exception, Eq)


runParseError :: (Error err :> es) => (ParseError -> err) -> Eff (Error ParseError : es) a -> Eff es a
runParseError f = runErrorNoCallStackWith @ParseError (throwError . f)
