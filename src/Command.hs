{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
module Command (
  runCommand
, searchPredicate
, filterPredicate
, search
, filter'
, globalCommands
, makeListWidget
, makeContentListWidget

-- * exported for testing
, argumentErrorMessage
, parseCommand
, parseMapping
) where

import           Data.List
import           Data.Map (Map, (!))
import qualified Data.Map as Map
import           Data.Char
import           Control.Arrow (second)
import           Text.Printf (printf)
import           System.Exit
import           System.Cmd (system)
import           Control.Monad.State (gets, get, modify, liftIO)
import           Control.Monad.Error (catchError)
import           Control.Monad
import           Control.Applicative

import           Network.MPD ((=?), Seconds)
import qualified Network.MPD as MPD hiding (withMPD)
import qualified Network.MPD.Commands.Extensions as MPDE
import           UI.Curses hiding (wgetch, ungetch, mvaddstr, err)

import           Vimus
import           ListWidget (ListWidget)
import qualified ListWidget
import           Util (maybeRead, match, MatchResult(..), addPlaylistSong, posixEscape)
import           Content
import           WindowLayout

import           System.FilePath ((</>))

-- | Widget commands
type WAction a  = a -> Vimus (Maybe a)
type WCommand a = (String, WAction a)

wCommand :: String -> WAction a -> WCommand a
wCommand = (,)

wModify :: a -> Vimus (Maybe a)
wModify = return . Just

wReturn :: Vimus (Maybe a)
wReturn = return Nothing

listCommands :: [WCommand (ListWidget a)]
listCommands = [
    wCommand "move-up"            $ wModify . ListWidget.moveUp
  , wCommand "move-down"          $ wModify . ListWidget.moveDown
  , wCommand "move-first"         $ wModify . ListWidget.moveFirst
  , wCommand "move-last"          $ wModify . ListWidget.moveLast
  , wCommand "scroll-up"          $ wModify . ListWidget.scrollUp
  , wCommand "scroll-down"        $ wModify . ListWidget.scrollDown
  , wCommand "scroll-page-up"     $ wModify . ListWidget.scrollPageUp
  , wCommand "scroll-page-down"   $ wModify . ListWidget.scrollPageDown

  , wCommand "move-out" $ \list ->
        case ListWidget.getParent list of
          Just p  -> wModify p
          Nothing -> wModify list

  ]

makeListCommands :: Handler (ListWidget a) -> ListWidget a -> [WidgetCommand]
makeListCommands handle list = flip map listCommands $ \(n, a) ->
  widgetCommand n $ fmap (makeListWidget handle) `fmap` a list

makeListWidget :: Handler (ListWidget a) -> ListWidget a -> Widget
makeListWidget handle list = Widget {
    render      = ListWidget.render list
  , title       = case ListWidget.getParent list of
      Just p  -> ListWidget.breadcrumbs p
      Nothing -> ""
  , commands    = makeListCommands handle list
  , event       = \ev -> do
    -- Process general handler for all lists first
    new <- handleList ev list

    -- Process the user's handle next
    res <- handle ev new
    case res of
      Nothing -> return $ makeListWidget handle new
      Just l  -> return $ makeListWidget handle l
  , currentItem = Nothing
  , searchItem  = \order term ->
      makeListWidget handle $ (searchFun order) (searchPredicate term list) list
  , filterItem  = \term ->
      makeListWidget handle $ ListWidget.filter (filterPredicate term list) list
  }

handleList :: Event -> ListWidget a -> Vimus (ListWidget a)
handleList ev list = case ev of
  EvResize (sizeY, _) -> return $ ListWidget.setViewSize list sizeY
  _                   -> return list

searchFun :: SearchOrder -> (a -> Bool) -> ListWidget a -> ListWidget a
searchFun Forward  = ListWidget.search
searchFun Backward = ListWidget.searchBackward

-- | ContentListWidget commands

contentListCommands :: [WCommand (ListWidget Content)]
contentListCommands = [
    -- Playlist: play selected song
    -- Library:  add song to playlist and play it
    -- Browse:   either add song to playlist and play it, or :move-in
    wCommand "default-action" $ \list -> do
      withCurrentItem list $ \item -> do
        case item of
          Dir   _         -> eval "move-in"
          PList _         -> eval "move-in"
          Song  song      -> songDefaultAction song
          PListSong p i _ -> addPlaylistSong p i >>= MPD.playId
      wReturn

    -- insert a song right after the current song
  , wCommand "insert" $ \list -> do
      withCurrentSong list $ \song -> do
        st <- MPD.status
        case MPD.stSongPos st of
          Just n -> do
            -- there is a current song, add after
            _ <- MPD.addId (MPD.sgFilePath song) (Just . fromIntegral $ n + 1)
            wModify $ ListWidget.moveDown list
          _                 -> do
            -- there is no current song, just add
            eval "add"
            wReturn

    -- Remove given song from playlist
  , wCommand "remove" $ \list -> do
      withCurrentSong list $ \song -> do
        case MPD.sgId song of
          (Just i) -> do MPD.deleteId i
          Nothing  -> return ()
      wReturn

  , wCommand "add-album" $ \list -> do
      withCurrentSong list $ \song -> do
        case Map.lookup MPD.Album $ MPD.sgTags song of
          Just l -> do
            songs <- mapM MPD.find $ map (MPD.Album =?) l
            MPDE.addMany "" $ map MPD.sgFilePath $ concat songs
          Nothing -> printStatus "Song has no album metadata!"
      wReturn

    -- Add given song to playlist
  , wCommand "add" $ \list -> do
      withCurrentItem list $ \item -> do
        case item of
          Dir   path      -> MPD.add_ path
          PList plst      -> MPD.load plst
          Song  song      -> MPD.add_ (MPD.sgFilePath song)
          PListSong p i _ -> void $ addPlaylistSong p i
      wModify $ ListWidget.moveDown list

  -- Browse inwards/outwards
  , wCommand "move-in" $ \list -> do
      withCurrentItem list $ \item -> do
        case item of
          Dir   path -> do
            new <- map toContent `fmap` MPD.lsInfo path
            wModify $ ListWidget.newChild new list
          PList path -> do
            new <- (map (uncurry $ PListSong path) . zip [0..]) `fmap` MPD.listPlaylistInfo path
            wModify $ ListWidget.newChild new list
          Song  _    -> wReturn
          PListSong _ _ _ -> wReturn

  ]

makeContentListCommands :: Handler (ListWidget Content) -> ListWidget Content -> [WidgetCommand]
makeContentListCommands handle list = flip map (contentListCommands ++ listCommands) $ \(n, a) ->
  widgetCommand n $ fmap (makeContentListWidget handle) `fmap` a list

makeContentListWidget :: Handler (ListWidget Content) -> ListWidget Content -> Widget
makeContentListWidget handle list = (makeListWidget handle list) {
    commands    = makeContentListCommands handle list
  , event       = \ev -> do
    -- Process general handler for all lists first
    new <- handleList ev list

    -- Process the user's handle next
    res <- handle ev new
    case res of
      Nothing -> return $ makeContentListWidget handle new
      Just l  -> return $ makeContentListWidget handle l

  , currentItem = ListWidget.select list
  , searchItem  = \order term ->
      makeContentListWidget handle $ (searchFun order) (searchPredicate term list) list
  , filterItem  = \term ->
      makeContentListWidget handle $ ListWidget.filter (filterPredicate term list) list
  }

command :: String -> (String -> Vimus ()) -> Command
command name action = Command name (Action action)

-- | Define a command that takes no arguments.
command0 :: String -> Vimus () -> Command
command0 name action = Command name (Action0 action)

-- | Define a command that takes one argument.
command1 :: String -> (String -> Vimus ()) -> Command
command1 name action = Command name (Action1 action)

-- | Define a command that takes two arguments.
-- command2 :: String -> (String -> String -> Vimus ()) -> Command
-- command2 name action = Command name (Action2 action)

-- | Define a command that takes three arguments.
command3 :: String -> (String -> String -> String -> Vimus ()) -> Command
command3 name action = Command name (Action3 action)

globalCommands :: [Command]
globalCommands = [
    command0 "help"               $ setCurrentView Help
  , command  "map"                $ addMapping
  , command0 "exit"               $ liftIO exitSuccess
  , command0 "quit"               $ liftIO exitSuccess
  , command3 "color"              $ defColor

  , command0 "repeat"             $ MPD.repeat  True
  , command0 "norepeat"           $ MPD.repeat  False
  , command0 "consume"            $ MPD.consume True
  , command0 "noconsume"          $ MPD.consume False
  , command0 "random"             $ MPD.random  True
  , command0 "norandom"           $ MPD.random  False
  , command0 "single"             $ MPD.single  True
  , command0 "nosingle"           $ MPD.single  False

  , command0 "toggle-repeat"      $ MPD.status >>= MPD.repeat  . not . MPD.stRepeat
  , command0 "toggle-consume"     $ MPD.status >>= MPD.consume . not . MPD.stConsume
  , command0 "toggle-random"      $ MPD.status >>= MPD.random  . not . MPD.stRandom
  , command0 "toggle-single"      $ MPD.status >>= MPD.single  . not . MPD.stSingle

  , command1 "set-library-path"   $ setLibraryPath

  , command0 "next"               $ MPD.next
  , command0 "previous"           $ MPD.previous
  , command0 "toggle"             $ MPDE.toggle
  , command0 "stop"               $ MPD.stop
  , command0 "update"             $ MPD.update []
  , command0 "rescan"             $ MPD.rescan []
  , command0 "clear"              $ MPD.clear
  , command0 "search-next"        $ searchNext
  , command0 "search-prev"        $ searchPrev
  , command0 "window-library"     $ setCurrentView Library
  , command0 "window-playlist"    $ setCurrentView Playlist
  , command0 "window-search"      $ setCurrentView SearchResult
  , command0 "window-browser"     $ setCurrentView Browser
  , command0 "window-next"        $ nextView
  , command0 "window-prev"        $ previousView

  , command  "!"                  $ runShellCommand

  , command1 "seek" $ \s -> do
      let err = (printStatus $ "invalid argument: '" ++ s ++ "'!")
      maybe err seek (maybeRead s)

 ]



defColor :: String -> String -> String -> Vimus ()
defColor col fg bg = do
  let color = wincRead col
  let fore  = colRead fg
  let back  = colRead bg

  case (color, fore, back) of
    (Just c, Just f, Just b) -> do
      liftIO $ defineColor c f b
      return ()
    _                        -> do
      printStatus "Unable to parse options!"

  where
    colRead name = case map toLower name of
      "default" -> Just defaultColor
      "black"   -> Just black
      "red"     -> Just red
      "green"   -> Just green
      "yellow"  -> Just yellow
      "blue"    -> Just blue
      "magenta" -> Just magenta
      "cyan"    -> Just cyan
      "white"   -> Just white
      _         -> Nothing

    wincRead name = case map toLower name of
      "main"           -> Just MainColor
      "tab"            -> Just TabColor
      "input"          -> Just InputColor
      "status"         -> Just StatusColor
      "playstatus"     -> Just PlayStatusColor
      "songstatus"     -> Just SongStatusColor
      _                -> Nothing

getCurrentPath :: Vimus (Maybe FilePath)
getCurrentPath = do
  mBasePath <- gets libraryPath
  mPath <- withCurrentWidget $ \widget -> do
    case currentItem widget of
      Just (Dir path)        -> return (Just path)
      Just (PList l)         -> return (Just l)
      Just (Song song)       -> return (Just $ MPD.sgFilePath song)
      Just (PListSong _ _ s) -> return (Just $ MPD.sgFilePath s)
      Nothing                -> return Nothing

  return $ (mBasePath `append` mPath) <|> mBasePath
  where
    append = liftA2 (</>)


expandCurrentPath :: String -> Maybe String -> Either String String
expandCurrentPath s mPath = go s
  where
    go ""             = return ""
    go ('\\':'\\':xs) = ('\\':) `fmap` go xs
    go ('\\':'%':xs)  = ('%':)  `fmap` go xs
    go ('%':xs)       = case mPath of
                          Nothing -> Left "Path to music library is not set, hence % can not be used!"
                          Just p  -> (posixEscape p ++) `fmap` go xs
    go (x:xs)         = (x:) `fmap` go xs

parseCommand :: String -> (String, String)
parseCommand s = (name, dropWhile isSpace arg)
  where
    (name, arg) = case dropWhile isSpace s of
      '!':xs -> ("!", xs)
      xs     -> span (not . isSpace) xs

-- | Evaluate command with given name
eval :: String -> Vimus ()
eval input = withCurrentWidget $ \widget ->
  case parseCommand input of
    ("", "") -> return ()
    (c, args) -> case match c $ Map.keys $ commandMap widget of
      None         -> printStatus $ printf "unknown command %s" c
      Match x      -> runAction args (commandMap widget ! x)
      Ambiguous xs -> printStatus $ printf "ambiguous command %s, could refer to: %s" c $ intercalate ", " xs

runAction :: String -> Action -> Vimus ()
runAction s action =
  case action of
    Action  a -> a s
    Action0 a -> case args of
      [] -> a
      xs -> argumentError 0 xs

    Action1 a -> case args of
      [x] -> a x
      xs  -> argumentError 1 xs

    Action2 a -> case args of
      [x, y] -> a x y
      xs     -> argumentError 2 xs

    Action3 a -> case args of
      [x, y, z] -> a x y z
      xs        -> argumentError 3 xs

  where
    args = words s

argumentError
  :: Int      -- ^ expected number of arguments
  -> [String] -- ^ actual arguments
  -> Vimus ()
argumentError n = printStatus . argumentErrorMessage n

argumentErrorMessage
  :: Int      -- ^ expected number of arguments
  -> [String] -- ^ actual arguments
  -> String
argumentErrorMessage n args =
  case drop n args of
    []  ->  reqMessage
    [x] -> "unexpected argument: " ++ x
    xs  -> "unexpected arguments: " ++ unwords xs
  where
    reqMessage
      | n == 1    = "one argument required"
      | n == 2    = "two arguments required"
      | n == 2    = "three arguments required"
      | otherwise = show n ++ " arguments required"

-- | Run command with given name
runCommand :: String -> Vimus ()
runCommand c = eval c `catchError` (printStatus . show)

commandMap :: Widget -> Map String Action
commandMap w = Map.fromList $ (map . second) fromWidgetAction (commands w) ++ zip (map commandName globalCommands) (map commandAction globalCommands)
  where
    fromWidgetAction :: WidgetAction -> Action
    fromWidgetAction wa = Action0 $ do
      new <- wa
      case new of
        Just r  -> setCurrentWidget r
        Nothing -> return ()


------------------------------------------------------------------------
-- commands

runShellCommand :: String -> Vimus ()
runShellCommand arg = (expandCurrentPath arg <$> getCurrentPath) >>= either printStatus action
  where
    action s = liftIO $ do
      endwin
      e <- system s
      case e of
        ExitSuccess   -> return ()
        ExitFailure n -> putStrLn ("shell returned " ++ show n)
      void getChar

-- | Currently only <cr> is expanded to '\n'.
expandKeyReferences :: String -> String
expandKeyReferences s =
  case s of
    ""                 -> ""
    '<':'c':'r':'>':xs -> '\n':expandKeyReferences xs
    x:xs               ->    x:expandKeyReferences xs

parseMapping :: String -> (String, String)
parseMapping s =
  case span (not . isSpace) (dropWhile isSpace s) of
    (macro, expansion) -> (macro, (expandKeyReferences . dropWhile isSpace) expansion)

addMapping :: String -> Vimus ()
addMapping s = case parseMapping s of
  ("", "") -> printStatus "not yet implemented" -- TODO: print all mappings
  (_, "")  -> printStatus "not yet implemented" -- TODO: print mapping with given name
  (m, e)   -> addMacro m e

seek :: Seconds -> Vimus ()
seek delta = do
  st <- MPD.status
  let (current, total) = MPD.stTime st
  let newTime = round current + delta
  if (newTime < 0)
    then do
      -- seek within previous song
      case MPD.stSongPos st of
        Just currentSongPos -> unless (currentSongPos == 0) $ do
          previousItem <- MPD.playlistInfo $ Just (currentSongPos - 1, 1)
          case previousItem of
            song : _ -> maybeSeek (MPD.sgId song) (MPD.sgLength song + newTime)
            _        -> return ()
        _ -> return ()
    else if (newTime > total) then
      -- seek within next song
      maybeSeek (MPD.stNextSongID st) (newTime - total)
    else
      -- seek within current song
      maybeSeek (MPD.stSongID st) newTime
  where
    maybeSeek (Just songId) time = MPD.seekId songId time
    maybeSeek Nothing _      = return ()

-- Add a currently selected song, if any, in regards to playlists and cue sheets
songDefaultAction :: MPD.Song -> Vimus ()
songDefaultAction song = case MPD.sgId song of
  -- song is already on the playlist
  Just i  -> MPD.playId i
  -- song is not yet on the playlist
  Nothing -> MPD.addId (MPD.sgFilePath song) Nothing >>= MPD.playId


-- | Print a message to the status line
printStatus :: String -> Vimus ()
printStatus message = do
  status <- get
  let window = statusLine status
  liftIO $ mvwaddstr window 0 0 message
  liftIO $ wclrtoeol window
  liftIO $ wrefresh window
  return ()




------------------------------------------------------------------------
-- search

search :: String -> Vimus ()
search term = do
  modify $ \state -> state { getLastSearchTerm = term }
  search_ Forward term

filter' :: String -> Vimus ()
filter' term = withCurrentWidget $ \widget -> do
  setCurrentView SearchResult
  setCurrentWidget $ filterItem widget term

searchNext :: Vimus ()
searchNext = do
  state <- get
  search_ Forward $ getLastSearchTerm state

searchPrev :: Vimus ()
searchPrev = do
  state <- get
  search_ Backward $ getLastSearchTerm state

search_ :: SearchOrder -> String -> Vimus ()
search_ order term = modifyCurrentWidget $ \widget ->
  return $ searchItem widget order term

searchPredicate :: String -> ListWidget s -> s -> Bool
searchPredicate = searchPredicate' Search

filterPredicate :: String -> ListWidget s -> s -> Bool
filterPredicate = searchPredicate' Filter

searchPredicate' :: SearchPredicate -> String -> ListWidget s -> s -> Bool
searchPredicate' predicate "" _ _ = onEmptyTerm predicate
  where
    onEmptyTerm Search = False
    onEmptyTerm Filter = True

searchPredicate' _ term list item = and $ map (\term_ -> or $ map (isInfixOf term_) tags) terms
  where
    tags = map (map toLower) $ ListWidget.getTags list item
    terms = words $ map toLower term
