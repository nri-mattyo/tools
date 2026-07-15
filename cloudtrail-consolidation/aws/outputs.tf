output "glue_job_name" {
  value = aws_glue_job.consolidate.name
}

output "glue_job_role_arn" {
  value = aws_iam_role.glue_job.arn
}

output "athena_database" {
  value = aws_glue_catalog_database.this.name
}

output "athena_table" {
  value = aws_glue_catalog_table.consolidated.name
}

output "quicksight_data_source_arn" {
  value = aws_quicksight_data_source.cloudtrail.arn
}

output "quicksight_data_set_arn" {
  value = aws_quicksight_data_set.cloudtrail.arn
}

output "quicksight_viewers_group_arn" {
  value = aws_quicksight_group.cloudtrail_viewers.arn
}

output "athena_dashboard_workgroup" {
  value = aws_athena_workgroup.dashboard.name
}
