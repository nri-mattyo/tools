# Same schema/DDL as athena_ddl.py's build_ddl() / cloudtrail_schema.py's
# DDL_COLUMNS -- keep the two in sync if either changes. Traditional Glue
# Catalog-registered partitions, kept current via MSCK REPAIR TABLE (run
# automatically by convert.py's consolidate() after any run that writes new
# data) -- see athena_ddl.py's module docstring for why this replaced an
# earlier partition-projection design (an unfiltered query had to probe
# thousands of candidate partitions before it could start scanning real data).

locals {
  # SCALAR_FIELDS ++ JSON_FIELDS ++ [ORIG_FILE_COLUMN] from cloudtrail_schema.py, lower-cased.
  athena_columns = [
    "eventversion", "eventtime", "eventsource", "eventname", "awsregion",
    "sourceipaddress", "useragent", "errorcode", "errormessage", "requestid",
    "eventid", "readonly", "eventtype", "apiversion", "recipientaccountid",
    "sharedeventid", "vpcendpointid", "eventcategory", "managementevent",
    "sessioncredentialfromconsole",
    "useridentity", "requestparameters", "responseelements", "additionaleventdata",
    "resources", "serviceeventdetails", "addendum", "edgedevicedetails", "tlsdetails",
    "orig_file",
  ]

  to_location = "s3://${var.to_bucket}/${var.to_prefix}"
}

resource "aws_glue_catalog_database" "this" {
  name = var.athena_database
}

resource "aws_glue_catalog_table" "consolidated" {
  name          = var.athena_table
  database_name = aws_glue_catalog_database.this.name
  table_type    = "EXTERNAL_TABLE"
  # Explicitly empty, not omitted: `parameters` is an Optional attribute, and
  # Terraform treats "absent from config" as "don't manage this attribute" --
  # it won't diff toward removing values that are already there (e.g. the
  # projection settings this table had before). Setting it to {} is what
  # actually tells Terraform to clear them.
  parameters = {}

  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }

  storage_descriptor {
    location      = local.to_location
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = local.athena_columns
      content {
        name = columns.value
        type = "string"
      }
    }
  }
}
