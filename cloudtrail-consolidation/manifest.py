"""manifest.json: tracks which source files (by full s3://bucket/key, matching
the orig_file column every consolidated row carries -- see cloudtrail_schema.py)
have already been merged into a given destination, so re-running `consolidate`
against the same --to is safe and incremental.

Keying by the full URL (not just the bare S3 key) matters once more than one
source bucket feeds the same destination, which is a real, expected setup
here (e.g. several accounts' CloudTrail buckets consolidated into one
analytics bucket) -- two different buckets can otherwise have identically-
shaped keys, and a bare key alone can't tell them apart.

Stored at s3://<to-bucket>/<to-prefix>_manifest/manifest.json.gz (a sibling of
the partitioned Parquet data, not inside it, so it's never picked up as a data
file by Athena/Glue). Read-modify-write: load once per run, merge in newly
processed keys, save once at the end. That's fine for one run at a time
against a given destination; concurrent overlapping runs against the *same*
destination could race on the final save and should use a real lock (e.g. a
DynamoDB table) instead -- not needed for the expected usage here.

Gzipped, not plain JSON: at real scale (millions of source files) this file
gets large (one production manifest is ~370MB uncompressed, ~53MB gzipped --
an 86% reduction), and every single `consolidate` run downloads it whole,
parses it, and re-uploads it whole just to diff "is this file new" -- so its
size directly drives the tool's per-run overhead. Also written with compact
(no-indent) JSON separators rather than pretty-printed, since indentation
alone roughly doubles a document this repetitive before compression even
starts. `_load()` transparently migrates an old plain-JSON manifest.json
(pre-compression) if no manifest.json.gz exists yet -- `save()` always
writes the compressed key from then on.
"""
import gzip
import json
from datetime import datetime, timezone

from botocore.exceptions import ClientError

# Chosen over gzip's default (9): at hundreds of MB, level 9 costs
# meaningfully more CPU time for only a marginal size improvement over 6.
_COMPRESSLEVEL = 6


def manifest_key(to_prefix):
    base = to_prefix if to_prefix.endswith("/") else to_prefix + "/"
    return f"{base}_manifest/manifest.json.gz"


def _legacy_manifest_key(to_prefix):
    """Pre-compression manifest path -- read once for migration if the
    compressed key doesn't exist yet; never written to again."""
    base = to_prefix if to_prefix.endswith("/") else to_prefix + "/"
    return f"{base}_manifest/manifest.json"


class Manifest:
    def __init__(self, s3_client, bucket, prefix):
        self.s3 = s3_client
        self.bucket = bucket
        self.key = manifest_key(prefix)
        self._legacy_key = _legacy_manifest_key(prefix)
        self.processed = {}  # orig_file (s3://bucket/key) -> {etag, size, records, processed_at}
        self._load()

    def _load(self):
        try:
            body = self.s3.get_object(Bucket=self.bucket, Key=self.key)["Body"].read()
        except ClientError as e:
            if e.response["Error"]["Code"] not in ("NoSuchKey", "404"):
                raise
            self._load_legacy()
            return
        self.processed = json.loads(gzip.decompress(body)).get("processed", {})

    def _load_legacy(self):
        """One-time migration path: no manifest.json.gz yet, but an older
        uncompressed manifest.json might exist from before this file format
        changed. save() writes only the compressed key going forward."""
        try:
            body = self.s3.get_object(Bucket=self.bucket, Key=self._legacy_key)["Body"].read()
        except ClientError as e:
            if e.response["Error"]["Code"] in ("NoSuchKey", "404"):
                return
            raise
        self.processed = json.loads(body).get("processed", {})

    def is_new(self, orig_file, etag):
        entry = self.processed.get(orig_file)
        if entry is None:
            return True
        if entry.get("etag") is None:
            # A rebuilt entry (see replace_all()/verify --rebuild-manifest) has
            # no ETag to compare against -- it was derived from data already
            # confirmed durable, so trust it's done rather than treating an
            # unknown ETag as "different, therefore new".
            return False
        return entry.get("etag") != etag

    def filter_new(self, bucket, objects):
        """objects: iterable of dicts with at least 'Key' and 'ETag' (as returned
        by list_objects_v2), all from `bucket`. Returns only the ones not
        already recorded (by full s3://bucket/key) with a matching ETag."""
        from s3url import to_s3_url  # local import: avoids a cycle, only needed here
        return [o for o in objects if self.is_new(to_s3_url(bucket, o["Key"]), o["ETag"])]

    def mark_processed(self, orig_file, etag, size, record_count, processed_at):
        self.processed[orig_file] = {
            "etag": etag,
            "size": size,
            "records": record_count,
            "processed_at": processed_at,
        }

    def backup(self):
        """Copy the current manifest.json to a timestamped sibling key before
        it's about to be overwritten wholesale (see replace_all()). Returns
        the backup key, or None if there was no existing manifest to back up."""
        try:
            self.s3.head_object(Bucket=self.bucket, Key=self.key)
        except ClientError as e:
            if e.response["Error"]["Code"] in ("404", "NoSuchKey"):
                return None
            raise
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup_key = f"{self.key}.bak-{ts}"
        self.s3.copy_object(Bucket=self.bucket, CopySource={"Bucket": self.bucket, "Key": self.key},
                             Key=backup_key)
        return backup_key

    def replace_all(self, processed):
        """Wholesale-replace the in-memory manifest (used by `verify
        --rebuild-manifest` to derive it straight from what's actually in the
        data). Caller is responsible for calling backup() first and save()
        after -- this only updates the in-memory state."""
        self.processed = processed

    def save(self):
        # No indent: pretty-printing buys nothing for a document nobody reads
        # by eye at this size, and it meaningfully inflates the pre-gzip byte
        # stream for something this repetitive.
        raw = json.dumps({"processed": self.processed}, separators=(",", ":"), sort_keys=True).encode()
        body = gzip.compress(raw, compresslevel=_COMPRESSLEVEL)
        self.s3.put_object(Bucket=self.bucket, Key=self.key, Body=body,
                            ContentType="application/json", ContentEncoding="gzip")
