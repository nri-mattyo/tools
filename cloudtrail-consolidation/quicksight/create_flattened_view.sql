-- Athena VIEW that flattens the JSON-encoded fields (useridentity, etc.) in
-- cloudtrail_logs.consolidated into plain columns, and derives a few boolean
-- flags used throughout the dashboard. QuickSight's dataset points at this
-- view rather than the raw table, so:
--   1. JSON extraction happens once, server-side, in Athena SQL (fast, and
--      testable/reusable outside QuickSight) instead of via QuickSight
--      calculated-field JSON functions, whose exact syntax/behavior varies
--      by QuickSight version.
--   2. Partition pruning on year/month/day still works: a VIEW in Athena is
--      just stored SQL, not a materialization -- QuickSight's generated
--      queries still filter the underlying table's partitions when a
--      dashboard filter/visual restricts year/month/day through the view.
--
-- WRITE OPERATION -- creates a Glue Catalog view. Needs explicit approval
-- before running. Run via Athena console/CLI against the cloudtrail_logs
-- database, e.g.:
--   aws athena start-query-execution \
--     --query-string file://create_flattened_view.sql \
--     --query-execution-context Database=cloudtrail_logs \
--     --work-group <workgroup> --profile nri-develop

CREATE OR REPLACE VIEW cloudtrail_logs.consolidated_flat AS
SELECT
  eventtime,
  CAST(from_iso8601_timestamp(eventtime) AS timestamp) AS event_timestamp,
  eventsource,
  eventname,
  awsregion,
  sourceipaddress,
  useragent,
  errorcode,
  errormessage,
  eventid,
  requestid,
  readonly,
  eventtype,
  recipientaccountid,
  eventcategory,
  managementevent,
  json_extract_scalar(useridentity, '$.arn')         AS actor_arn,
  json_extract_scalar(useridentity, '$.type')        AS actor_type,
  json_extract_scalar(useridentity, '$.userName')    AS actor_username,
  json_extract_scalar(useridentity, '$.accountId')   AS actor_account_id,
  json_extract_scalar(useridentity, '$.principalId') AS actor_principal_id,
  -- text 'true'/'false' rather than Athena BOOLEAN, so the type QuickSight
  -- sees is an unambiguous STRING regardless of QuickSight/driver version.
  CASE WHEN errorcode IS NOT NULL AND errorcode <> '' THEN 'true' ELSE 'false' END AS is_error,
  CASE WHEN lower(readonly) = 'false' THEN 'true' ELSE 'false' END AS is_write_event,
  orig_file,
  -- Provenance label -- lets the dashboard show source-trail overlap/dedup
  -- state directly (see ../cleanup/CLEANUP_PLAN.md for the underlying
  -- duplication analysis this reuses).
  CASE
    WHEN orig_file LIKE '%aws-cloudtrail-logs-381492092437-74dbd159%' THEN 'api-events'
    WHEN orig_file LIKE '%nri-cloudtrail-logs-381492092437%' THEN 'main-cloudtrail'
    WHEN orig_file LIKE '%nri-cloudtrail-logs-637423466983%' THEN 'nri-customer'
    WHEN orig_file LIKE '%aws-cloudtrail-logs-293034550673-c21dd2f3%' THEN 'newton'
    ELSE 'other'
  END AS source_trail,
  year,
  month,
  day
FROM cloudtrail_logs.consolidated;
