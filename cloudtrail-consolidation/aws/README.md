# cloudtrail-consolidation infra

Deploys:
- a Glue **Python Shell** job (not Spark -- cheapest DPU tier, no cluster
  cold-start) that runs `cli.py consolidate`, with an IAM role scoped to
  read `from_bucket/from_prefix` and read/write `to_bucket/to_prefix`
- the Athena database/table over the consolidated Parquet (`athena.tf`) --
  identical DDL to what `python cli.py create-table` prints, kept here so
  both are declared as infra. Partitions are traditional Glue Catalog
  entries, kept current via `MSCK REPAIR TABLE` (run automatically by
  `consolidate` after any run that writes new data) -- see "Athena schema"
  in the main README for why this isn't partition projection.

## Deploy

```bash
# 1. Upload the tool's script + local modules once (and after any code change):
cd ..
zip -r /tmp/cloudtrail-consolidation.zip cli.py convert.py manifest.py s3url.py \
  cloudtrail_schema.py athena_ddl.py defaults.py stats.py filters/
aws s3 cp /tmp/cloudtrail-consolidation.zip \
  s3://<script_bucket>/cloudtrail-consolidation/cloudtrail-consolidation.zip
aws s3 cp cli.py s3://<script_bucket>/cloudtrail-consolidation/cli.py

# 2. Apply
cd aws
terraform init
terraform apply \
  -var region=us-east-1 \
  -var from_bucket=nri-cloudtrail-logs-381492092437 \
  -var from_prefix=cloudtrail-logs/AWSLogs/381492092437/CloudTrail/ \
  -var to_bucket=my-consolidated-bucket \
  -var to_prefix=cloudtrail/ \
  -var script_bucket=<script_bucket>
```

`aws_glue_job` only points at `cli.py` as the entrypoint script
(`script_location`); Glue Python Shell doesn't unpack a zip for you the way
`--extra-py-files` does for local modules -- pass the zip's S3 URI via
`--extra-py-files` in `default_arguments` if you go this route, or (simpler)
just run the tool as the plain CLI locally/cron and skip the Glue job entirely
-- `main.tf`'s job resource is there for when/if you want it scheduled via
Glue triggers or EventBridge, not required for day-to-day use.

## Run

```bash
aws glue start-job-run --job-name cloudtrail-consolidation \
  --arguments '{"--from":"s3://.../CloudTrail/*/2026/07/01/","--to":"s3://my-consolidated-bucket/cloudtrail/"}'
```

(`cli.py`'s `argparse` setup reads `--from`/`--to` the same way whether
invoked directly or via Glue's `--arguments`.)
