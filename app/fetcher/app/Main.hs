import           Control.Concurrent  (getNumCapabilities)
import           Options.Applicative
import           System.IO

import qualified BuildRetrieval
import qualified DbHelpers
import qualified Scanning
import qualified SqlRead
import qualified SqlWrite


data CommandLineArgs = NewCommandLineArgs {
    buildCount   :: Int
  , ageDays      :: Int
  , branchName   :: [String]
  , dbHostname   :: String
  , dbPassword   :: String
  , wipeDatabase :: Bool
    -- ^ Suppress console output
  }


myCliParser :: Parser CommandLineArgs
myCliParser = NewCommandLineArgs
  <$> option auto (long "count"       <> value 3           <> metavar "BUILD_COUNT"
    <> help "Maximum number of failed builds to fetch from CircleCI")
  <*> option auto (long "age"         <> value 365         <> metavar "AGE_DAYS"
    <> help "Maximum age of build to fetch from CircleCI")
  <*> some (strOption   (long "branch" <> metavar "BRANCH_NAME"
    <> help "Branch name (can specify multiple)"))
  <*> strOption   (long "db-hostname" <> value "localhost" <> metavar "DATABASE_HOSTNAME"
    <> help "Hostname of database")
  <*> strOption   (long "db-password" <> value "logan01" <> metavar "DATABASE_PASSWORD"
    <> help "Password for database user")
   -- Note: this is not the production password; this default is only for local testing
  <*> switch      (long "wipe"
    <> help "Wipe database content before beginning")


mainAppCode :: CommandLineArgs -> IO ()
mainAppCode args = do

  hSetBuffering stdout LineBuffering

  capability_count <- getNumCapabilities
  print $ "Num capabilities: " ++ show capability_count

  conn <- SqlWrite.prepare_database connection_data $ wipeDatabase args

  BuildRetrieval.updateBuildsList conn (branchName args) fetch_count age_days

  scan_resources <- Scanning.prepare_scan_resources conn

  visited_builds_list <- SqlRead.get_revisitable_builds conn
  Scanning.rescan_visited_builds scan_resources visited_builds_list

  unvisited_builds_list <- SqlRead.get_unvisited_build_ids conn fetch_count
  Scanning.process_unvisited_builds scan_resources unvisited_builds_list

  where
    fetch_count = buildCount args
    age_days = ageDays args

    connection_data = DbHelpers.NewDbConnectionData {
        DbHelpers.dbHostname = dbHostname args
      , DbHelpers.dbName = "loganci"
      , DbHelpers.dbUsername = "logan"
      , DbHelpers.dbPassword = dbPassword args
      }


main :: IO ()
main = execParser opts >>= mainAppCode
  where
    opts = info (helper <*> myCliParser)
      ( fullDesc
     <> progDesc "Scans CircleCI failure logs"
     <> header "fetcher - performs the scan, populates database" )
