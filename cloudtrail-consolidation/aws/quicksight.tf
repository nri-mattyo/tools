# QuickSight infra for the CloudTrail consolidated-data dashboard. See
# ../quicksight/QUICKSIGHT_PLAN.md for the full design/best-practice writeup
# and ../quicksight/DASHBOARD_DESIGN.md for the sheet/visual layout.
#
# Scope note: this file provisions the STABLE, mechanical pieces -- a
# dedicated Athena workgroup, IAM access for QuickSight's service role, the
# QuickSight data source + dataset, and a viewers group. The
# analysis/dashboard's sheets and visuals are deliberately NOT modeled here:
# QuickSight's `definition` schema for sheets/visuals is deep and easy to
# get wrong without live visual feedback. Recommended workflow: build/
# iterate the dashboard in the QuickSight console against the dataset below,
# then export the finished design with `aws quicksight
# describe-dashboard-definition` (command in the plan doc) and fold the
# result into an `aws_quicksight_dashboard.definition` block here once the
# design is settled, so it becomes reproducible/versioned like the rest of
# this infra.
#
# Prerequisite (run once, needs its own approval -- see
# ../quicksight/create_flattened_view.sql): the Athena view
# `${var.athena_database}.${var.athena_flattened_view}` must already exist
# before this file's dataset can be applied.

data "aws_caller_identity" "quicksight" {}

# ---- dedicated Athena workgroup for dashboard queries ----
# Kept separate from "primary" (used for ad hoc analyst queries elsewhere in
# this account) so dashboard query costs are visible on their own, and so a
# runaway/unfiltered dashboard query can't consume the whole account's
# Athena budget. bytes_scanned_cutoff_per_query is the actual cost
# guardrail -- the consolidated table is already tens of millions of rows
# across a multi-year, multi-region history and growing daily; every
# visual/filter should be scoped by year/month/day, but this is the
# backstop for when one isn't.
resource "aws_athena_workgroup" "dashboard" {
  name = "${var.app_name}-quicksight"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_dashboard_workgroup_bytes_scanned_cutoff

    result_configuration {
      output_location = "s3://${var.to_bucket}/${var.app_name}-quicksight-results/"
    }
  }
}

# ---- QuickSight's own service role gets Athena/Glue/S3 access ----
# QuickSight always queries Athena via its own auto-created service role
# (aws-quicksight-service-role-v0), not a role passed into the data source
# resource. This grants that role exactly what it needs for this one
# workgroup/table/view -- nothing broader. The role must already exist
# (QuickSight creates it the first time any Athena/Redshift/RDS data source
# is added in the account -- already true here, see "benchmark-results").
data "aws_iam_role" "quicksight_service_role" {
  name = "aws-quicksight-service-role-v0"
}

resource "aws_iam_role_policy" "quicksight_athena_access" {
  name = "${var.app_name}-quicksight-athena"
  role = data.aws_iam_role.quicksight_service_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaDashboardWorkgroup"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:GetQueryExecution",
          "athena:GetQueryResults", "athena:StopQueryExecution", "athena:GetWorkGroup",
        ]
        Resource = aws_athena_workgroup.dashboard.arn
      },
      {
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = ["glue:GetTable", "glue:GetTables", "glue:GetDatabase", "glue:GetDatabases", "glue:GetPartitions"]
        Resource = [
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.quicksight.account_id}:catalog",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.quicksight.account_id}:database/${var.athena_database}",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.quicksight.account_id}:table/${var.athena_database}/${var.athena_table}",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.quicksight.account_id}:table/${var.athena_database}/${var.athena_flattened_view}",
        ]
      },
      {
        Sid      = "ReadConsolidatedData"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.to_bucket}", "arn:aws:s3:::${var.to_bucket}/${var.to_prefix}*"]
      },
      {
        # GetBucketLocation is separate from GetObject/PutObject/ListBucket --
        # Athena's "verify/create output bucket" check on workgroup connection
        # test calls it directly, and its absence is what a
        # GENERIC_SQL_FAILURE: "Unable to verify/create output bucket" error
        # on aws_quicksight_data_source actually means (not a bucket that's
        # missing -- a bucket-level permission that is).
        Sid      = "AthenaResultsBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = ["arn:aws:s3:::${var.to_bucket}", "arn:aws:s3:::${var.to_bucket}/${var.app_name}-quicksight-results/*"]
      },
    ]
  })
}

# ---- data source ----
resource "aws_quicksight_data_source" "cloudtrail" {
  data_source_id = "${var.app_name}-athena"
  name           = "CloudTrail Consolidated"
  type           = "ATHENA"

  parameters {
    athena {
      work_group = aws_athena_workgroup.dashboard.name
    }
  }

  dynamic "permission" {
    for_each = var.quicksight_admin_principals
    content {
      principal = permission.value
      actions = [
        "quicksight:DescribeDataSource", "quicksight:DescribeDataSourcePermissions",
        "quicksight:PassDataSource", "quicksight:UpdateDataSource",
        "quicksight:DeleteDataSource", "quicksight:UpdateDataSourcePermissions",
      ]
    }
  }
}

# ---- dataset ----
# Points at the flattened Athena VIEW (see
# ../quicksight/create_flattened_view.sql), not the raw table directly --
# JSON fields (useridentity etc.) are pre-flattened server-side in Athena
# SQL, which is more reliable than QuickSight calculated-field JSON parsing
# and keeps partition pruning intact (the view still selects year/month/day
# straight through from the base table, so QuickSight's generated Athena
# queries still filter on those partitions when a dashboard filter does).
#
# DIRECT_QUERY import mode, per your call: no SPICE ingestion step, the
# dashboard always reflects the latest partition written by convert.py, at
# the cost of per-view Athena query latency. If dashboard interactivity
# becomes a problem later, the standard fix is a separate small SPICE
# dataset over a pre-aggregated daily rollup (not the raw table) for the
# high-level sheet, with drill-down sheets falling back to this Direct
# Query dataset for row-level detail -- see QUICKSIGHT_PLAN.md "SPICE
# escape hatch".
resource "aws_quicksight_data_set" "cloudtrail" {
  data_set_id = "${var.app_name}-consolidated"
  name        = "CloudTrail Consolidated"
  import_mode = "DIRECT_QUERY"

  physical_table_map {
    physical_table_map_id = "consolidated-flat"

    relational_table {
      data_source_arn = aws_quicksight_data_source.cloudtrail.arn
      name            = var.athena_flattened_view
      schema          = var.athena_database

      input_columns {
        name = "event_timestamp"
        type = "DATETIME"
      }
      input_columns {
        name = "eventid"
        type = "STRING"
      }
      input_columns {
        name = "requestid"
        type = "STRING"
      }
      input_columns {
        name = "eventsource"
        type = "STRING"
      }
      input_columns {
        name = "eventname"
        type = "STRING"
      }
      input_columns {
        name = "awsregion"
        type = "STRING"
      }
      input_columns {
        name = "sourceipaddress"
        type = "STRING"
      }
      input_columns {
        name = "errorcode"
        type = "STRING"
      }
      input_columns {
        name = "errormessage"
        type = "STRING"
      }
      input_columns {
        name = "is_error"
        type = "STRING"
      }
      input_columns {
        name = "is_write_event"
        type = "STRING"
      }
      input_columns {
        name = "eventtype"
        type = "STRING"
      }
      input_columns {
        name = "eventcategory"
        type = "STRING"
      }
      input_columns {
        name = "recipientaccountid"
        type = "STRING"
      }
      input_columns {
        name = "actor_arn"
        type = "STRING"
      }
      input_columns {
        name = "actor_type"
        type = "STRING"
      }
      input_columns {
        name = "actor_username"
        type = "STRING"
      }
      input_columns {
        name = "actor_account_id"
        type = "STRING"
      }
      input_columns {
        name = "source_trail"
        type = "STRING"
      }
      input_columns {
        name = "orig_file"
        type = "STRING"
      }
      input_columns {
        name = "year"
        type = "STRING"
      }
      input_columns {
        name = "month"
        type = "STRING"
      }
      input_columns {
        name = "day"
        type = "STRING"
      }
    }
  }

  logical_table_map {
    logical_table_map_id = "consolidated-flat-logical"
    alias                = "CloudTrail Consolidated"

    source {
      physical_table_id = "consolidated-flat"
    }
  }

  dynamic "permissions" {
    for_each = var.quicksight_admin_principals
    content {
      principal = permissions.value
      # Must exactly match one of QuickSight's two allowed action sets for a
      # dataset (owner or viewer) -- anything else 400s at apply time, even
      # a superficially reasonable subset/superset.
      actions = [
        "quicksight:DescribeDataSet", "quicksight:DescribeDataSetPermissions",
        "quicksight:PassDataSet", "quicksight:DescribeIngestion", "quicksight:ListIngestions",
        "quicksight:UpdateDataSet", "quicksight:DeleteDataSet",
        "quicksight:CreateIngestion", "quicksight:CancelIngestion", "quicksight:UpdateDataSetPermissions",
      ]
    }
  }
}

# ---- viewers group ----
# Read-only permission boundary, separate from the admin principals above --
# grant this group's ARN view-only permissions on the dashboard once it
# exists (see QUICKSIGHT_PLAN.md's permissions section), rather than
# granting individual users directly.
resource "aws_quicksight_group" "cloudtrail_viewers" {
  group_name  = "${var.app_name}-viewers"
  description = "Read-only QuickSight access to the CloudTrail consolidated dashboard."
  namespace   = var.quicksight_namespace
}
