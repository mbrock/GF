{-# LANGUAGE CPP, ScopedTypeVariables, TypeSynonymInstances,FlexibleInstances #-}
-- | GF interactive mode (with the C run-time system)
module GF.Interactive2 (mainGFI,mainRunGFI{-,mainServerGFI-}) where
import Prelude hiding (putStrLn,print)
import qualified Prelude as P(putStrLn)
import GF.Command.Interpreter(CommandEnv(..),commands,mkCommandEnv,interpretCommandLine)
--import GF.Command.Importing(importSource,importGrammar)
import GF.Command.Commands2(flags,options,PGFEnv,HasPGFEnv(..),pgf,concs,pgfEnv,emptyPGFEnv,pgfCommands)
import GF.Command.CommonCommands
import GF.Command.Help(helpCommand)
import GF.Command.Abstract
import GF.Command.Parse(readCommandLine,pCommand)
import GF.Data.Operations (Err(..),done)
import GF.Data.Utilities(repeatM)

import GF.Infra.UseIO(ioErrorText,putStrLnE)
import GF.Infra.SIO
import GF.Infra.Option
import qualified System.Console.Haskeline as Haskeline
--import GF.Text.Coding(decodeUnicode,encodeUnicode)

--import GF.Compile.Coding(codeTerm)

import qualified PGF2 as C
import qualified PGF as H

import Data.Char
import Data.List(isPrefixOf)
import qualified Data.Map as Map

import qualified Text.ParserCombinators.ReadP as RP
--import System.IO(utf8)
--import System.CPUTime(getCPUTime)
import System.Directory({-getCurrentDirectory,-}getAppUserDataDirectory)
import System.FilePath(takeExtensions)
import Control.Exception(SomeException,fromException,try)
--import Control.Monad
import Control.Monad.State

import qualified GF.System.Signal as IO(runInterruptibly)
{-
#ifdef SERVER_MODE
import GF.Server(server)
#endif
-}

import GF.Command.Messages(welcome)

-- | Run the GF Shell in quiet mode (@gf -run@).
mainRunGFI :: Options -> [FilePath] -> IO ()
mainRunGFI opts files = shell (beQuiet opts) files

beQuiet = addOptions (modifyFlags (\f -> f{optVerbosity=Quiet}))

-- | Run the interactive GF Shell
mainGFI :: Options -> [FilePath] -> IO ()
mainGFI opts files = do
  P.putStrLn welcome
  P.putStrLn "This shell uses the C run-time system. See help for available commands."
  shell opts files

shell opts files = flip evalStateT emptyGFEnv $
                   do mapStateT runSIO $ importInEnv opts files
                      loop opts

{-
#ifdef SERVER_MODE
-- | Run the GF Server (@gf -server@).
-- The 'Int' argument is the port number for the HTTP service.
mainServerGFI opts0 port files =
    server jobs port root (execute1 opts)
      =<< runSIO (importInEnv emptyGFEnv opts files)
  where
    root = flag optDocumentRoot opts
    opts = beQuiet opts0
    jobs = join (flag optJobs opts)
#else
mainServerGFI opts files =
  error "GF has not been compiled with server mode support"
#endif
-}
-- | Read end execute commands until it is time to quit
loop :: Options -> StateT GFEnv IO ()
loop opts = repeatM $ readAndExecute1 opts

-- | Read and execute one command, returning Just an updated environment for
-- | the next command, or Nothing when it is time to quit
readAndExecute1 :: Options -> StateT GFEnv IO Bool
readAndExecute1 opts =
    mapStateT runSIO . execute1 opts =<< readCommand opts

-- | Read a command
readCommand :: Options -> StateT GFEnv IO String
readCommand opts =
    case flag optMode opts of
      ModeRun -> lift tryGetLine
      _       -> lift . fetchCommand =<< get

timeIt act =
  do t1 <- liftSIO $ getCPUTime
     a <-  act
     t2 <- liftSIO $ getCPUTime
     return (t2-t1,a)

-- | Optionally show how much CPU time was used to run an IO action
optionallyShowCPUTime :: (Monad m,MonadSIO m) => Options -> m a -> m a
optionallyShowCPUTime opts act 
  | not (verbAtLeast opts Normal) = act
  | otherwise = do (dt,r) <- timeIt act
                   liftSIO $ putStrLnFlush $ show (dt `div` 1000000000) ++ " msec"
                   return r

{-
loopOptNewCPU opts gfenv' 
 | not (verbAtLeast opts Normal) = return gfenv'
 | otherwise = do 
     cpu' <- getCPUTime
     putStrLnE (show ((cpu' - cputime gfenv') `div` 1000000000) ++ " msec")
     return $ gfenv' {cputime = cpu'}
-}

type ShellM = StateT GFEnv SIO

-- | Execute a given command, returning Just an updated environment for
-- | the next command, or Nothing when it is time to quit
execute1 :: Options -> String -> ShellM Bool
execute1 opts s0 =
  do modify $ \ gfenv0 -> gfenv0 {history = s0 : history gfenv0}
     interruptible $ optionallyShowCPUTime opts $
       case pwords s0 of
      -- cc, sd, so, ss and dg are now in GF.Commands.SourceCommands
      -- special commands
         "q" :_   -> quit
         "!" :ws  -> system_command ws
         "eh":ws  -> eh ws
         "i" :ws  -> import_ ws
      -- other special commands, working on GFEnv
         "e" :_   -> empty
         "dc":ws  -> define_command ws
         "dt":ws  -> define_tree ws
         "ph":_   -> print_history
         "r" :_   -> reload_last
      -- ordinary commands
         _        -> do env <- gets commandenv
                        interpretCommandLine env s0
                        continue
  where
--  loopNewCPU = fmap Just . loopOptNewCPU opts
    continue,stop :: ShellM Bool
    continue = return True
    stop = return False

    pwords s = case words s of
                 w:ws -> getCommandOp w :ws
                 ws -> ws

    interruptible :: ShellM Bool -> ShellM Bool
    interruptible act =
      do gfenv <- get
         mapStateT (
           either (\e -> printException e >> return (True,gfenv)) return
             <=< runInterruptibly) act

  -- Special commands:

    quit = do when (verbAtLeast opts Normal) $ putStrLnE "See you."
              stop

    system_command ws = do lift $ restrictedSystem $ unwords ws ; continue


       {-"eh":w:_ -> do
                  cs <- readFile w >>= return . map words . lines
                  gfenv' <- foldM (flip (process False benv)) gfenv cs
                  loopNewCPU gfenv' -}
    eh [w] = -- Ehhh? Reads commands from a file, but does not execute them
      do env <- gets commandenv
         cs <- lift $ restricted (readFile w) >>= return . map (interpretCommandLine env) . lines
         continue
    eh _   = do putStrLnE "eh command not parsed"
                continue

    import_ args = 
      do case parseOptions args of
           Ok (opts',files) -> do
             curr_dir <- lift getCurrentDirectory
             lib_dir  <- lift $ getLibraryDirectory (addOptions opts opts')
             importInEnv (addOptions opts (fixRelativeLibPaths curr_dir lib_dir opts')) files
             continue
           Bad err ->
             do putStrLnE $ "Command parse error: " ++ err
                continue
         continue

    empty = do modify $ \ gfenv -> gfenv { commandenv=emptyCommandEnv }
               continue

    define_command (f:ws) =
        case readCommandLine (unwords ws) of
           Just comm ->
             do modify $
                  \ gfenv ->
                    let env = commandenv gfenv
                    in gfenv {
                         commandenv = env {
                           commandmacros = Map.insert f comm (commandmacros env)
                         }
                       }
                continue
           _ -> dc_not_parsed
    define_command _ = dc_not_parsed

    dc_not_parsed = putStrLnE "command definition not parsed" >> continue

    define_tree (f:ws) =
        case H.readExpr (unwords ws) of
          Just exp ->
           do modify $
                \ gfenv ->
                  let env = commandenv gfenv
                  in gfenv { commandenv = env {
                               expmacros = Map.insert f exp (expmacros env) } }
              continue
          _ -> dt_not_parsed
    define_tree _ = dt_not_parsed

    dt_not_parsed = putStrLnE "value definition not parsed" >> continue

    print_history =
      do mapM_ putStrLnE . reverse . drop 1 . history =<< get
         continue

    reload_last = do
      gfenv0 <- get
      let imports = [(s,ws) | s <- history gfenv0, ("i":ws) <- [pwords s]]
      case imports of
        (s,ws):_ -> do
          putStrLnE $ "repeating latest import: " ++ s
          import_ ws
        _ -> do
          putStrLnE $ "no import in history"
          continue


printException e = maybe (print e) (putStrLn . ioErrorText) (fromException e)

fetchCommand :: GFEnv -> IO String
fetchCommand gfenv = do
  path <- getAppUserDataDirectory "gf_history"
  let settings =
        Haskeline.Settings {
          Haskeline.complete = wordCompletion gfenv,
          Haskeline.historyFile = Just path,
          Haskeline.autoAddHistory = True
        }
  res <- IO.runInterruptibly $ Haskeline.runInputT settings (Haskeline.getInputLine (prompt gfenv))
  case res of
    Left  _        -> return ""
    Right Nothing  -> return "q"
    Right (Just s) -> return s

importInEnv :: Options -> [FilePath] -> ShellM ()
importInEnv opts files =
  case files of
    _ | flag optRetainResource opts ->
          putStrLnE "Flag -retain is not supported in this shell"
    [file] | takeExtensions file == ".pgf" -> importPGF file
    [] -> done
    _ -> do putStrLnE "Can only import one .pgf file"
  where
    importPGF file =
      do gfenv <- get
         case multigrammar gfenv of
           Just _ -> putStrLnE "Discarding previous grammar"
           _ -> done
         pgf1 <- lift $ readPGF2 file
         let gfenv' = gfenv { pgfenv = pgfEnv pgf1 }
         when (verbAtLeast opts Normal) $
           let langs = Map.keys . concretes $ gfenv'
           in putStrLnE . unwords $ "\nLanguages:":langs
         put gfenv'

tryGetLine = do
  res <- try getLine
  case res of
   Left (e :: SomeException) -> return "q"
   Right l -> return l

prompt env = abs ++ "> "
  where
    abs = maybe "" C.abstractName (multigrammar env)

data GFEnv = GFEnv {
--grammar :: (), -- gfo grammar -retain
--retain :: (),  -- grammar was imported with -retain flag
  pgfenv :: PGFEnv,
  commandenv :: CommandEnv ShellM,
  history    :: [String]
  }

emptyGFEnv :: GFEnv
emptyGFEnv = GFEnv {-() ()-} emptyPGFEnv emptyCommandEnv [] {-0-}

emptyCommandEnv = mkCommandEnv allCommands
multigrammar = pgf . pgfenv
concretes = concs . pgfenv

allCommands =
  extend pgfCommands [helpCommand allCommands]
  `Map.union` commonCommands

instance HasPGFEnv ShellM where getPGFEnv = gets pgfenv

-- ** Completion

wordCompletion gfenv (left,right) = do
  case wc_type (reverse left) of
    CmplCmd pref
      -> ret (length pref) [Haskeline.simpleCompletion name | name <- Map.keys (commands cmdEnv), isPrefixOf pref name]
{-
    CmplStr (Just (Command _ opts _)) s0
      -> do mb_state0 <- try (evaluate (H.initState pgf (optLang opts) (optType opts)))
            case mb_state0 of
              Right state0 -> let (rprefix,rs) = break isSpace (reverse s0)
                                  s            = reverse rs
                                  prefix       = reverse rprefix
                                  ws           = words s
                              in case loop state0 ws of
                                   Nothing    -> ret 0 []
                                   Just state -> let compls = H.getCompletions state prefix
                                                 in ret (length prefix) (map (\x -> Haskeline.simpleCompletion x) (Map.keys compls))
              Left (_ :: SomeException) -> ret 0 []
-}
    CmplOpt (Just (Command n _ _)) pref
      -> case Map.lookup n (commands cmdEnv) of
           Just inf -> do let flg_compls = [Haskeline.Completion ('-':flg++"=") ('-':flg) False | (flg,_) <- flags   inf, isPrefixOf pref flg]
                              opt_compls = [Haskeline.Completion ('-':opt)      ('-':opt) True | (opt,_) <- options inf, isPrefixOf pref opt]
                          ret (length pref+1)
                              (flg_compls++opt_compls)
           Nothing  -> ret (length pref) []
    CmplIdent (Just (Command "i" _ _)) _        -- HACK: file name completion for command i
      -> Haskeline.completeFilename (left,right)

    CmplIdent _ pref
      -> case mb_pgf of
           Just pgf -> ret (length pref)
                           [Haskeline.simpleCompletion name 
                            | name <- C.functions pgf,
                              isPrefixOf pref name]
           _ -> ret (length pref) []

    _ -> ret 0 []
  where
    mb_pgf = multigrammar gfenv
    cmdEnv = commandenv gfenv
{-
    optLang opts = valStrOpts "lang" (head $ Map.keys (concretes cmdEnv)) opts
    optType opts = 
      let str = valStrOpts "cat" (H.showCId $ H.lookStartCat pgf) opts
      in case H.readType str of
           Just ty -> ty
           Nothing -> error ("Can't parse '"++str++"' as type")

    loop ps []     = Just ps
    loop ps (t:ts) = case H.nextState ps (H.simpleParseInput t) of
                       Left  es -> Nothing
                       Right ps -> loop ps ts
-}
    ret len xs  = return (drop len left,xs)


data CompletionType
  = CmplCmd                   Ident
  | CmplStr   (Maybe Command) String
  | CmplOpt   (Maybe Command) Ident
  | CmplIdent (Maybe Command) Ident
  deriving Show

wc_type :: String -> CompletionType
wc_type = cmd_name
  where
    cmd_name cs =
      let cs1 = dropWhile isSpace cs
      in go cs1 cs1
      where
        go x []       = CmplCmd x
        go x (c:cs)
          | isIdent c = go x cs
          | otherwise = cmd x cs

    cmd x []       = ret CmplIdent x "" 0
    cmd _ ('|':cs) = cmd_name cs
    cmd _ (';':cs) = cmd_name cs
    cmd x ('"':cs) = str x cs cs
    cmd x ('-':cs) = option x cs cs
    cmd x (c  :cs)
      | isIdent c  = ident x (c:cs) cs
      | otherwise  = cmd x cs

    option x y []       = ret CmplOpt x y 1
    option x y ('=':cs) = optValue x y cs
    option x y (c  :cs)
      | isIdent c       = option x y cs
      | otherwise       = cmd x cs
      
    optValue x y ('"':cs) = str x y cs
    optValue x y cs       = cmd x cs

    ident x y []     = ret CmplIdent x y 0
    ident x y (c:cs)
      | isIdent c    = ident x y cs
      | otherwise    = cmd x cs

    str x y []          = ret CmplStr x y 1
    str x y ('\"':cs)   = cmd x cs
    str x y ('\\':c:cs) = str x y cs
    str x y (c:cs)      = str x y cs

    ret f x y d = f cmd y
      where
        x1 = take (length x - length y - d) x
        x2 = takeWhile (\c -> isIdent c || isSpace c || c == '-' || c == '=' || c == '"') x1
        
        cmd = case [x | (x,cs) <- RP.readP_to_S pCommand x2, all isSpace cs] of
	        [x] -> Just x
                _   -> Nothing

    isIdent c = c == '_' || c == '\'' || isAlphaNum c
