variable "region" {
  description = "AWS region for the Glue job, Athena database/table, and script bucket."
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Name used for the Glue job and IAM role."
  type        = string
  default     = "cloudtrail-consolidation"
}

# ---- source / destination ----
variable "from_bucket" {
  description = "Bucket the raw CloudTrail logs live in (read-only access granted to the job)."
  type        = string
}

variable "from_prefix" {
  description = "Prefix under from_bucket the job is allowed to read (e.g. \"cloudtrail-logs/AWSLogs/123456789012/CloudTrail/\"). The job's --from argument is passed at run time, but IAM access is scoped to this prefix."
  type        = string
}

variable "to_bucket" {
  description = "Destination bucket for consolidated Parquet + manifest.json (read/write access granted to the job)."
  type        = string
}

variable "to_prefix" {
  description = "Prefix under to_bucket the job writes into. Also the LOCATION prefix for the Athena table below."
  type        = string
}

# ---- script deployment ----
variable "script_bucket" {
  description = "S3 bucket the Glue Python Shell script and its dependencies are uploaded to."
  type        = string
}

variable "script_key" {
  description = "S3 key for the uploaded cli.py entrypoint (upload the whole cloudtrail-consolidation/ dir as a .zip or use --additional-python-modules for awswrangler and --extra-py-files for the local modules)."
  type        = string
  default     = "cloudtrail-consolidation/cli.py"
}

# ---- Athena ----
variable "athena_database" {
  description = "Glue Catalog / Athena database name for the consolidated table."
  type        = string
  default     = "cloudtrail_logs"
}

variable "athena_table" {
  description = "Athena table name for the consolidated Parquet dataset."
  type        = string
  default     = "consolidated"
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the Glue job's logs."
  type        = number
  default     = 14
}

# ---- QuickSight (see ../quicksight/QUICKSIGHT_PLAN.md) ----
variable "quicksight_namespace" {
  description = "QuickSight namespace users/groups belong to."
  type        = string
  default     = "default"
}

variable "quicksight_admin_principals" {
  description = "QuickSight user/group ARNs granted owner (edit) permissions on the data source, dataset, and dashboard -- e.g. [\"arn:aws:quicksight:us-east-1:381492092437:group/default/cloudtrail-dashboard-admins\"]."
  type        = list(string)
}

variable "athena_flattened_view" {
  description = "Athena view name (in athena_database) with JSON fields flattened for QuickSight. Create it once via quicksight/create_flattened_view.sql before applying this Terraform -- the aws_quicksight_data_set below expects it to already exist."
  type        = string
  default     = "consolidated_flat"
}

variable "athena_dashboard_workgroup_bytes_scanned_cutoff" {
  description = "Per-query bytes-scanned cutoff (bytes) for the dashboard's dedicated Athena workgroup -- guards against an unfiltered scan of the full (multi-TB and growing) consolidated table. Default 100 GB."
  type        = number
  default     = 107374182400
}
