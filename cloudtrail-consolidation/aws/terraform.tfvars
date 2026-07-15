region = "us-east-1"
from_bucket = "nri-cloudtrail-logs-381492092437"
from_prefix = "cloudtrail-logs/AWSLogs/381492092437/CloudTrail/"
to_bucket = "nri-cloudtrail-logs-381492092437"
to_prefix = "cloudtrail-logs/raw/parquet/"
script_bucket = "nri-cloudtrail-logs-381492092437"

quicksight_admin_principals = [
  "arn:aws:quicksight:us-east-1:381492092437:user/default/AWSReservedSSO_AdministratorAccess_19ad65eaa60cf0a6/matt-oullette",
  "arn:aws:quicksight:us-east-1:381492092437:user/default/AWSReservedSSO_AdministratorAccess_19ad65eaa60cf0a6/fabio-elia",
  "arn:aws:quicksight:us-east-1:381492092437:user/default/AWSReservedSSO_AdministratorAccess_19ad65eaa60cf0a6/bill-brissette",
]
