{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module SqlWrite where

import           Builds
import           Control.Exception                 (throwIO)
import qualified Data.ByteString.Char8             as BS
import           Data.Foldable                     (for_)
import qualified Data.Maybe                        as Maybe
import           Data.Text                         (Text)
import qualified Data.Text                         as T
import           Data.Time.Format                  (defaultTimeLocale,
                                                    formatTime,
                                                    rfc822DateFormat)
import           Data.Traversable                  (for)
import           Database.PostgreSQL.Simple
import           Database.PostgreSQL.Simple.Errors
import           GHC.Int                           (Int64)

import qualified ApiPost
import qualified AuthStages
import qualified Breakages
import qualified DbHelpers
import qualified ScanPatterns
import qualified ScanRecords
import qualified ScanUtils
import qualified SqlRead


defaultPatternAuthor :: AuthStages.Username
defaultPatternAuthor = AuthStages.Username "kostmo"


build_to_tuple :: Build -> (Int64, Text, Text, Text, Text)
build_to_tuple (NewBuild (NewBuildNumber build_num) vcs_rev queuedat jobname branch) =
  (build_num, vcs_rev, queued_at_string, jobname, branch)
  where
    queued_at_string = T.pack $ formatTime defaultTimeLocale rfc822DateFormat queuedat


-- | This is idempotent; builds that are already present will not be overwritten
store_builds_list :: Connection -> [Build] -> IO Int64
store_builds_list conn builds_list =
  executeMany conn sql $ map build_to_tuple builds_list
  where
    sql = "INSERT INTO builds(build_num, vcs_revision, queued_at, job_name, branch) VALUES(?,?,?,?,?) ON CONFLICT (build_num) DO NOTHING;"


store_matches ::
     ScanRecords.ScanCatchupResources
  -> BuildStepId
  -> BuildNumber
  -> [ScanPatterns.ScanMatch]
  -> IO Int64
store_matches scan_resources (NewBuildStepId build_step_id) _build_num scoped_matches =
  executeMany conn insertion_sql $ map to_tuple scoped_matches

  where
    conn = ScanRecords.db_conn $ ScanRecords.fetching scan_resources
    scan_id = ScanRecords.scan_id scan_resources

    to_tuple match = (
        scan_id
      , build_step_id
      , DbHelpers.db_id $ ScanPatterns.scanned_pattern match
      , ScanPatterns.line_number match_deets
      , ScanPatterns.line_text match_deets
      , ScanPatterns.start $ ScanPatterns.span match_deets
      , ScanPatterns.end $ ScanPatterns.span match_deets
      )
      where
        match_deets = ScanPatterns.match_details match

    insertion_sql = "INSERT INTO matches(scan_id, build_step, pattern, line_number, line_text, span_start, span_end) VALUES(?,?,?,?,?,?,?);"


insert_posted_github_status ::
     DbHelpers.DbConnectionData
  -> Text
  -> DbHelpers.OwnerAndRepo
  -> ApiPost.StatusPostResult
  -> IO Int64
insert_posted_github_status conn_data git_sha1 (DbHelpers.OwnerAndRepo owner repo) (ApiPost.StatusPostResult id url state desc target_url context created_at updated_at) = do
  conn <- DbHelpers.get_connection conn_data
  [Only pattern_id] <- query conn sql (id, git_sha1, owner, repo, url, state, desc, target_url, context, created_at, updated_at)
  return pattern_id
  where
    sql = "INSERT INTO created_github_statuses(id, sha1, project, repo, url, state, description, target_url, context, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?) RETURNING id;"


insert_single_pattern :: Connection -> AuthStages.Username -> ScanPatterns.Pattern -> IO Int64
insert_single_pattern conn (AuthStages.Username username) (ScanPatterns.NewPattern expression_obj description tags applicable_steps specificity is_retired) = do

  [Only pattern_id] <- query conn pattern_insertion_sql (ScanPatterns.is_regex expression_obj, ScanPatterns.pattern_text expression_obj, description, is_retired, has_nondeterminisic_values, specificity)

  execute conn authorship_insertion_sql (pattern_id, username)

  for_ tags $ \tag -> do
    execute conn tag_insertion_sql (tag, pattern_id)

  for_ applicable_steps $ \applicable_step ->
    execute conn applicable_step_insertion_sql (applicable_step, pattern_id)

  return pattern_id

  where
    has_nondeterminisic_values = case expression_obj of
      ScanPatterns.RegularExpression _ has_nondeterministic -> has_nondeterministic
      ScanPatterns.LiteralExpression _                       -> False

    pattern_insertion_sql = "INSERT INTO patterns(regex, expression, description, is_retired, has_nondeterministic_values, specificity) VALUES(?,?,?,?,?,?) RETURNING id;"
    tag_insertion_sql = "INSERT INTO pattern_tags(tag, pattern) VALUES(?,?);"
    authorship_insertion_sql = "INSERT INTO pattern_authorship(pattern, author) VALUES(?,?);"
    applicable_step_insertion_sql = "INSERT INTO pattern_step_applicability(step_name, pattern) VALUES(?,?);"


restore_patterns :: DbHelpers.DbConnectionData -> AuthStages.Username -> [DbHelpers.WithAuthorship ScanPatterns.DbPattern] -> IO (Either Text [Int64])
restore_patterns conn_data user pattern_list = do
  conn <- DbHelpers.get_connection conn_data
  eithers <- for pattern_list $ api_new_pattern conn user . DbHelpers.record . DbHelpers.payload
  return $ sequenceA eithers


step_failure_to_tuple :: (BuildNumber, Either BuildStepFailure ScanRecords.UnidentifiedBuildFailure) -> (Int64, Maybe Text, Bool)
step_failure_to_tuple (NewBuildNumber buildnum, visitation_result) = case visitation_result of
  Right _ -> (buildnum, Nothing, False)
  Left (NewBuildStepFailure stepname mode) -> let
    is_timeout = case mode of
      BuildTimeoutFailure              -> True
      ScannableFailure _failure_output -> False
    in (buildnum, Just stepname, is_timeout)


store_log_info :: ScanRecords.ScanCatchupResources -> BuildStepId -> ScanRecords.LogInfo -> IO Int64
store_log_info scan_resources (NewBuildStepId step_id) (ScanRecords.LogInfo byte_count line_count log_content) = do

  execute conn sql (step_id, line_count, byte_count, log_content)

  where
    sql = "INSERT INTO log_metadata(step, line_count, byte_count, content) VALUES(?,?,?,?) ON CONFLICT (step) DO NOTHING;"
    conn = ScanRecords.db_conn $ ScanRecords.fetching scan_resources


insert_latest_pattern_build_scan :: ScanRecords.ScanCatchupResources -> BuildNumber -> Int64 -> IO ()
insert_latest_pattern_build_scan scan_resources (NewBuildNumber build_number) pattern_id = do

  execute conn sql (ScanRecords.scan_id scan_resources, build_number, pattern_id)
  return ()

  where
    sql = "INSERT INTO scanned_patterns(scan, build, newest_pattern) VALUES(?,?,?);"
    conn = ScanRecords.db_conn $ ScanRecords.fetching scan_resources


insert_build_visitation :: ScanRecords.ScanCatchupResources -> (BuildNumber, Either BuildStepFailure ScanRecords.UnidentifiedBuildFailure) -> IO BuildStepId
insert_build_visitation scan_resources visitation = do

  [Only step_id] <- query conn sql $ step_failure_to_tuple visitation
  return $ NewBuildStepId step_id
  where
    sql = "INSERT INTO build_steps(build, name, is_timeout) VALUES(?,?,?) RETURNING id;"
    conn = ScanRecords.db_conn $ ScanRecords.fetching scan_resources


insert_scan_id :: Connection -> ScanRecords.PatternId -> IO Int64
insert_scan_id conn (ScanRecords.NewPatternId pattern_id)  = do
  [Only pattern_id] <- query conn sql $ Only pattern_id
  return pattern_id
  where
    sql = "INSERT INTO scans(latest_pattern_id) VALUES(?) RETURNING id;"


api_new_pattern_test :: DbHelpers.DbConnectionData -> Builds.BuildNumber -> ScanPatterns.Pattern -> IO (Either String [ScanPatterns.ScanMatch])
api_new_pattern_test conn_data build_number@(Builds.NewBuildNumber buildnum) new_pattern = do

  conn <- DbHelpers.get_connection conn_data

  -- TODO consolidate with Scanning.scan_log
  maybe_console_log <- SqlRead.read_log conn build_number
  return $ case maybe_console_log of
    Just console_log -> Right $
      Maybe.mapMaybe apply_pattern $ zip [0::Int ..] $ map T.stripEnd $ T.lines console_log
    Nothing -> Left $ "No log found for build number " ++ show buildnum

  where
    apply_pattern :: (Int, Text) -> Maybe ScanPatterns.ScanMatch
    apply_pattern line_tuple = ScanUtils.apply_single_pattern line_tuple $ DbHelpers.WithId 0 new_pattern


api_new_breakage_report ::
     DbHelpers.DbConnectionData
  -> Breakages.BreakageReport
  -> IO (Either Text Int64)
api_new_breakage_report
    conn_data
    (Breakages.NewBreakageReport rev implicated_rev is_broken notes (AuthStages.Username author_username)) = do

  conn <- DbHelpers.get_connection conn_data
  catchViolation catcher $ do

    [Only report_id] <- query conn insertion_sql (rev, implicated_rev, author_username, notes, is_broken)
    return $ Right report_id

  where
    insertion_sql = "INSERT INTO broken_revisions(revision, implicated_revision, reporter, notes, is_broken) VALUES(?,?,?,?,?) RETURNING id;"

    catcher _ (UniqueViolation some_error) = return $ Left $ "Insertion error: " <> T.pack (BS.unpack some_error)
    catcher e _                                  = throwIO e


api_new_pattern ::
     Connection
  -> AuthStages.Username
  -> ScanPatterns.Pattern
  -> IO (Either Text Int64)
api_new_pattern conn author_username new_pattern = do

  catchViolation catcher $ do
    record_id <- insert_single_pattern conn author_username new_pattern
    return $ Right record_id

  where
    catcher _ (UniqueViolation some_error) = return $ Left $ "Insertion error: " <> T.pack (BS.unpack some_error)
    catcher e _                                  = throwIO e


