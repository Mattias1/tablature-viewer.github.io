module Main where

import HalogenUtils
import Prelude

import Clipboard (copyToClipboard)
import Data.Array (fromFoldable)
import Data.List (findIndex, (!!))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (class MonadEffect)
import Effect.Console as Console
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import LZString (compressToEncodedURIComponent, decompressFromEncodedURIComponent)
import LocationString (getFragmentString, getLocationString, setFragmentString)
import TablatureParser (TablatureDocument, TablatureDocumentLine(..), tryParseTablature)
import TablatureRenderer (renderTablature)
import UrlShortener (createShortUrl)
import Web.DOM (Element)
import Web.DOM.Element (scrollTop)
import Web.HTML (window)
import Web.HTML as WH
import Web.HTML.HTMLDocument (setTitle)
import Web.HTML.HTMLElement (toElement)
import Web.HTML.HTMLTextAreaElement as WH.HTMLTextAreaElement
import Web.HTML.Window (document)

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  runUI component unit body

data Mode = ViewMode | EditMode
type State =
  { mode :: Mode
  , tablatureText :: String
  , tablatureTitle :: String
  , tablatureDocument :: Maybe TablatureDocument
  -- Store the scrollTop in the state before actions so we can restore the expected scrollTop when switching views
  , scrollTop :: Number
  }
data Action = Initialize | ToggleMode | CopyShortUrl

defaultTitle :: String
defaultTitle = "Tab Viewer"

getTitle :: TablatureDocument -> String
getTitle tablatureDocument = 
  case findIndex isTitle tablatureDocument of
    Nothing -> defaultTitle
    Just index ->
      case tablatureDocument !! index of
        Just (TitleLine line) -> line.title
        Nothing -> defaultTitle
        Just _ -> defaultTitle
  where
  isTitle (TitleLine _) = true
  isTitle _ = false

instance showMode :: Show Mode where
  show ViewMode = "View Mode"
  show EditMode = "Edit Mode"

otherMode :: Mode -> Mode
otherMode EditMode = ViewMode
otherMode ViewMode = EditMode

refTablatureContainer :: H.RefLabel
refTablatureContainer = H.RefLabel "tablatureContainer"

refTablatureEditor :: H.RefLabel
refTablatureEditor = H.RefLabel "tablatureEditor"

component :: forall query input output m. MonadAff m => H.Component query input output m
component =
  H.mkComponent
    { initialState
    , render
    , eval: H.mkEval H.defaultEval 
      { handleAction = handleAction 
      , initialize = Just Initialize
      }
    }

initialState :: forall input. input -> State
initialState _ = { mode: EditMode, tablatureText: "", tablatureTitle: defaultTitle, tablatureDocument: Nothing, scrollTop: 0.0 }

render :: forall m. State -> H.ComponentHTML Action () m
render state = HH.div 
  [ classString "main" ]
  [ renderHeader
  , renderTablature
  ]
  where
  renderTablature = HH.div 
      [ classString "tablatureContainer", HP.ref refTablatureContainer ]
      [ case state.mode of
        ViewMode -> HH.div 
          [ classString "tablatureViewer" ]
          [ HH.pre_ $ renderTablatureText state ]
        EditMode -> HH.textarea
          [ HP.ref refTablatureEditor
          , classString "tablatureEditor" 
          , HP.placeholder "Paste your plaintext tablature here"
          , HP.spellcheck false
          ]
      ]
  renderHeader = HH.div
    [ classString "header" ]
    [ renderTitle
    , renderControls
    ]
  renderTitle = HH.div
    [ classString "title optional"]
    [ HH.a
      [ HP.href "https://github.com/dznl/tabviewer"
      , HP.target "_blank"
      ]
      [ HH.h1_ [ HH.text "Dozenal Tablature Viewer" ] ]
    ]
  renderControls = HH.div 
    [ classString "controls" ]
    [ HH.button [ HP.title toggleButtonTitle, HE.onClick \_ -> ToggleMode ] toggleButtonContent
    , HH.button
      [ HP.title "Create a short link to the tablature for sharing with other people"
      , HE.onClick \_ -> CopyShortUrl
      ] [ fontAwesome "fa-share", optionalText " Share" ]
    , HH.a
      [ HP.href "./"
      , HP.target "_blank"
      ]
      [ HH.button [ HP.title "Open a tablature in a new browser tab" ] [ fontAwesome "fa-plus", optionalText " New" ] ]
    , HH.a
      [ HP.href "https://github.com/dznl/tabviewer"
      , HP.target "_blank"
      ]
      [ HH.button [ HP.title "Open the README in a new browser tab" ] [ fontAwesome "fa-info", optionalText " About" ] ]
    ]
    where
    toggleButtonContent = case state.mode of
      EditMode -> [ fontAwesome "fa-save", optionalText " Save" ]
      ViewMode  -> [ fontAwesome "fa-edit", optionalText " Edit" ]
    toggleButtonTitle = case state.mode of
      EditMode -> "Save tablature"
      ViewMode  -> "Edit tablature"


renderTablatureText :: forall w i. State -> Array (HH.HTML w i)
renderTablatureText state = fromFoldable $ renderTablature state.tablatureDocument state.tablatureText

handleAction :: forall output m. MonadAff m => Action -> H.HalogenM State Action () output m Unit
handleAction action =
  case action of
    Initialize -> do
      maybeTablatureText <- H.liftEffect getTablatureTextFromFragment
      case maybeTablatureText of
        Just tablatureText -> do
          case tryParseTablature tablatureText of
            Just tablatureDocument -> do
              H.put { mode: ViewMode, tablatureText: tablatureText, tablatureTitle, tablatureDocument: Just tablatureDocument, scrollTop: 0.0 }
              H.liftEffect $ setDocumentTitle tablatureTitle
              where tablatureTitle = getTitle tablatureDocument
            Nothing ->
              H.put { mode: EditMode, tablatureText: tablatureText, tablatureTitle: defaultTitle, tablatureDocument: Nothing, scrollTop: 0.0 }
        Nothing ->
          H.put { mode: EditMode, tablatureText: "", tablatureTitle: defaultTitle, tablatureDocument: Nothing, scrollTop: 0.0 }
    ToggleMode -> do
      saveScrollTop
      state <- H.get
      case state.mode of
        EditMode -> do
          saveTablature
          H.modify_ _ { mode = ViewMode }
        ViewMode -> do
          H.modify_ _ { mode = EditMode, tablatureDocument = Nothing }
          setTablatureEditorText state.tablatureText
    CopyShortUrl -> do
      longUrl <- H.liftEffect getLocationString
      maybeShortUrl <- H.liftAff $ createShortUrl longUrl
      H.liftEffect $ case maybeShortUrl of
        Just shortUrl -> copyToClipboard shortUrl
        Nothing -> pure unit

getTablatureContainerElement :: forall output m. H.HalogenM State Action () output m (Maybe WH.HTMLElement)
getTablatureContainerElement = H.getHTMLElementRef refTablatureContainer 

saveScrollTop :: forall output m . MonadEffect m => H.HalogenM State Action () output m Unit
saveScrollTop = do
  maybeTablatureContainerElem <- getTablatureContainerElement <#> \maybeHtmlElement -> maybeHtmlElement <#> toElement
  case maybeTablatureContainerElem of
    Nothing -> pure unit
    Just tablatureContainerElem -> do
      newScrollTop <- H.liftEffect $ scrollTop tablatureContainerElem
      H.modify_ _ { scrollTop = newScrollTop }

focusTablatureContainer :: forall output m . MonadEffect m => H.HalogenM State Action () output m Unit
focusTablatureContainer = do
  maybeTablatureContainerElem <- getTablatureContainerElement
  case maybeTablatureContainerElem of
    Nothing -> pure unit
    Just tablatureContainerElem -> focus tablatureContainerElem


getTablatureEditorElement :: forall output m. H.HalogenM State Action () output m (Maybe WH.HTMLTextAreaElement)
getTablatureEditorElement = H.getHTMLElementRef refTablatureEditor <#>
  \maybeHtmlElement -> maybeHtmlElement >>= WH.HTMLTextAreaElement.fromHTMLElement

getTablatureEditorText :: forall output m . MonadEffect m => H.HalogenM State Action () output m String
getTablatureEditorText = do
  maybeTextArea <- getTablatureEditorElement
  case maybeTextArea of
    Nothing -> H.liftEffect $ Console.error "Could not find textareaTablature" *> pure ""
    Just textArea -> H.liftEffect $ WH.HTMLTextAreaElement.value textArea 

saveTablature :: forall output m . MonadEffect m => H.HalogenM State Action () output m Unit
saveTablature = do
  tablatureText <- getTablatureEditorText
  saveTablatureToState tablatureText
  saveTablatureToFragment
  where
  saveTablatureToState :: String -> H.HalogenM State Action () output m Unit
  saveTablatureToState tablatureText = do
    case tryParseTablature tablatureText of
      Just tablatureDocument ->
        H.modify_ _ { tablatureText = tablatureText, tablatureTitle = getTitle tablatureDocument, tablatureDocument = Just tablatureDocument }
      Nothing ->
        H.modify_ _ { tablatureText = tablatureText, tablatureTitle = defaultTitle, tablatureDocument = Nothing }
  saveTablatureToFragment :: H.HalogenM State Action () output m Unit
  saveTablatureToFragment = do
    state <- H.get
    H.liftEffect $ setDocumentTitle state.tablatureTitle
    case compressToEncodedURIComponent state.tablatureText of
      Just compressed -> H.liftEffect $ setFragmentString compressed
      Nothing -> H.liftEffect $ Console.error("Could not save tablature to URL")

getTablatureTextFromFragment :: Effect (Maybe String)
getTablatureTextFromFragment = do
  fragment <- H.liftEffect getFragmentString
  if fragment == "" || fragment == "#"
  then pure Nothing
  else case decompressFromEncodedURIComponent fragment of
    Just decompressed -> pure $ Just decompressed
    Nothing -> Console.error("Could not load tablature from URL") *> (pure Nothing)

setTablatureEditorText :: forall output m . MonadEffect m => String -> H.HalogenM State Action () output m Unit
setTablatureEditorText text = do
  maybeTextArea <- getTablatureEditorElement
  case maybeTextArea of
    Nothing -> H.liftEffect $ Console.error "Could not find textareaTablature" *> pure unit
    Just textArea -> H.liftEffect $ WH.HTMLTextAreaElement.setValue text textArea 

setDocumentTitle :: String -> Effect Unit
setDocumentTitle title = do
    window <- window
    document <- document window
    setTitle title document
