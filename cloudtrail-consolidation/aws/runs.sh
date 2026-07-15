#!/usr/bin/env bash
terraform init
terraform apply \
  -var region=us-east-1 \
  -var from_bucket=nri-cloudtrail-logs-381492092437 \
  -var from_prefix=cloudtrail-logs/AWSLogs/381492092437/CloudTrail/ \
  -var to_bucket=nri-cloudtrail-logs-381492092437 \
  -var to_prefix=cloudtrail-logs/raw/parquet/ \
  -var script_bucket=nri-cloudtrail-logs-381492092437
