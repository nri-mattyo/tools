"""Reads back what's actually durable in the primary Parquet dataset (via the
orig_file column every row carries -- see cloudtrail_schema.py) and compares
it against manifest.json, closing the gap between "we believe we wrote X" and
"X is verifiably, durably in S3". A batch's manifest commit already only
happens once its flush is confirmed complete (see convert.py's
settle_pending_flush()) -- this is a second, independent check of the actual
written artifact, not a replacement for that.

Also the tool for `verify --rebuild-manifest`: replacing manifest.json
outright with counts derived straight from the data. As a side effect this is
also how an old bare-key manifest (from before manifest.py was fixed to key by
full s3://bucket/key) gets migrated -- rebuilt keys come straight from
orig_file, which already has the correct shape. Rebuilt entries lose each
file's ETag (only the source bucket has that, and rebuilding reads the
*output*, not the source) -- see manifest.py's Manifest.is_new() for how a
null ETag is handled on future runs.
"""
import logging
from datetime import datetime, timezone

import awswrangler as wr
from botocore.config import Config

from defaults import DEFAULT_WORKERS
from manifest import Manifest
from s3url import to_s3_url

log = logging.getLogger("verify")


def list_primary_parquet_files(s3, bucket, prefix):
    """Only the primary dataset's files (year=.../month=.../day=.../*.parquet)
    directly under prefix -- deliberately excludes filter subpaths (e.g.
    errors_and_writes/), since those only ever hold a subset of the primary
    data and would understate/mismatch counts if mixed in."""
    files = []
    token = None
    while True:
        kwargs = {"Bucket": bucket, "Prefix": prefix}
        if token:
            kwargs["ContinuationToken"] = token
        resp = s3.list_objects_v2(**kwargs)
        for obj in resp.get("Contents", []):
            rel = obj["Key"][len(prefix):]
            if rel.startswith("year=") and obj["Key"].endswith(".parquet"):
                files.append(obj["Key"])
        if not resp.get("IsTruncated"):
            break
        token = resp.get("NextContinuationToken")
    return files


def actual_counts(session, bucket, prefix, workers=DEFAULT_WORKERS):
    """{orig_file: actual row count} aggregated directly from the written
    Parquet data. Only reads the orig_file column (Parquet is columnar, so
    this doesn't touch the rest of each row) -- cheap even at scale."""
    # Same fix as convert.py's consolidate(): awswrangler's internal S3 client
    # (created here by read_parquet, not one we pass in directly) explicitly
    # hardcodes max_pool_connections=10 in its own default config, which wins
    # over anything set on the session -- wr.config.botocore_config is the
    # only override it actually checks first. Without this, awswrangler's own
    # internal read concurrency across many Parquet files exhausts the pool,
    # degrading things enough to trip real read timeouts on a large dataset
    # (seen in practice, not just theoretical -- see the first real run of
    # this command). read_timeout is also bumped defensively, and retries are
    # set to adaptive/10-attempt so a flaky connection (seen in practice: a
    # mobile hotspot prone to brief disconnects) gets retried automatically
    # instead of aborting the whole run on one transient timeout.
    pool_config = Config(max_pool_connections=workers + 8, read_timeout=120,
                          retries={"max_attempts": 10, "mode": "adaptive"})
    wr.config.botocore_config = pool_config
    s3 = session.client("s3", config=pool_config)
    files = list_primary_parquet_files(s3, bucket, prefix)
    if not files:
        return {}
    paths = [to_s3_url(bucket, key) for key in files]
    df = wr.s3.read_parquet(path=paths, columns=["orig_file"], boto3_session=session)
    return df["orig_file"].value_counts().to_dict()


def verify(session, bucket, prefix, rebuild=False, workers=DEFAULT_WORKERS):
    """Compare manifest.json's recorded per-file counts against what's
    actually in the data. Returns a report dict. With rebuild=True, also
    backs up and replaces manifest.json with counts derived straight from the
    data."""
    s3 = session.client("s3")
    manifest = Manifest(s3, bucket, prefix)
    actual = actual_counts(session, bucket, prefix, workers=workers)

    mismatched = []
    for orig_file, entry in manifest.processed.items():
        expected = entry.get("records", 0)
        found = actual.get(orig_file, 0)
        if found != expected:
            mismatched.append((orig_file, expected, found))
    missing_from_manifest = sorted(set(actual) - set(manifest.processed))

    report = {
        "manifest_entries": len(manifest.processed),
        "distinct_files_in_data": len(actual),
        "total_rows_in_data": sum(actual.values()),
        "mismatched": sorted(mismatched),
        "missing_from_manifest": missing_from_manifest,
    }

    if rebuild:
        backup_key = manifest.backup()
        if backup_key:
            log.info("backed up existing manifest to s3://%s/%s", bucket, backup_key)
        else:
            log.info("no existing manifest.json to back up")
        now = datetime.now(timezone.utc).isoformat()
        manifest.replace_all({
            orig_file: {"etag": None, "size": None, "records": count, "processed_at": now}
            for orig_file, count in actual.items()
        })
        manifest.save()
        log.info("rebuilt manifest.json from %d file(s) found in the data", len(actual))

    return report
