module App.Colors where

import NSO.Prelude
import Web.UI

data AppColor
  = White
  | Light
  | GrayLight
  | GrayDark
  | Dark
  | Success
  | Error
  | Warning
  | Primary
  | PrimaryLight
  | Secondary
  deriving (Show)

instance ToColor AppColor where
  colorValue White = "#FFF"
  colorValue Light = "#F2F2F3"
  colorValue GrayLight = "#E3E5E9"
  colorValue GrayDark = "#2С3С44"
  colorValue Dark = "#2E3842" -- "#232C41"
  colorValue Primary = "#2C74BB"
  colorValue PrimaryLight = "#3281cf"
  colorValue Secondary = "#5CADDB"
  colorValue Success = "67C837"
  colorValue Error = "DF2020"
  colorValue Warning = "EBAF47"
