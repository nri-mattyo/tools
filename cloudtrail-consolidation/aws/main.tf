data "aws_caller_identity" "current" {}

# ---- IAM: what the Glue job itself is allowed to do ----
resource "aws_iam_role" "glue_job" {
  name        = "${var.app_name}-job-role"
  description = "Glue Python Shell job role for cloudtrail-consolidation."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "glue_job" {
  name = "${var.app_name}-perms"
  role = aws_iam_role.glue_job.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSourceList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.from_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["${var.from_prefix}*"] }
        }
      },
      {
        Sid      = "ReadSourceObjects"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${var.from_bucket}/${var.from_prefix}*"
      },
      {
        Sid      = "WriteDestList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.to_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["${var.to_prefix}*"] }
        }
      },
      {
        Sid      = "WriteDestObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.to_bucket}/${var.to_prefix}*"
      },
      {
        Sid      = "ReadScript"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.script_bucket}/*"
      },
      {
        Sid    = "GlueCatalogForAthenaCreateTable"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:CreateDatabase",
          "glue:GetTable", "glue:CreateTable", "glue:UpdateTable",
        ]
        Resource = [
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:database/${var.athena_database}",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.athena_database}/${var.athena_table}",
        ]
      },
      {
        Sid    = "AthenaCreateTableQuery"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws-glue/python-jobs/${var.app_name}"
  retention_in_days = var.log_retention_days
}

# ---- the job itself: Python Shell, not Spark -- no cluster, cheapest DPU tier,
# billed per second with no ~1 min cold start. --additional-python-modules
# installs awswrangler; --extra-py-files ships this tool's local modules
# (s3url.py, manifest.py, convert.py, cloudtrail_schema.py, athena_ddl.py,
# filters/) alongside the cli.py entrypoint uploaded at script_key.
resource "aws_glue_job" "consolidate" {
  name     = var.app_name
  role_arn = aws_iam_role.glue_job.arn

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${var.script_bucket}/${var.script_key}"
  }

  max_capacity      = 0.0625 # cheapest Python Shell tier
  max_retries       = 0
  timeout           = 60 # minutes; raise for large backfills
  glue_version      = "3.0"

  default_arguments = {
    "--additional-python-modules" = "awswrangler>=3.9"
    "--job-language"              = "python"
  }
}
