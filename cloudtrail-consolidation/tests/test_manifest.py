"""manifest.py: dedup keying, ETag change detection, gzip compression, legacy
migration, and the backup/rebuild primitives used by `verify --rebuild-manifest`."""
import gzip
import json

from manifest import Manifest, manifest_key


def test_manifest_key_lives_alongside_data_not_inside_a_partition():
    assert manifest_key("cloudtrail/") == "cloudtrail/_manifest/manifest.json.gz"
    assert manifest_key("cloudtrail") == "cloudtrail/_manifest/manifest.json.gz"  # no trailing slash


def test_dedup_keys_by_full_s3_url_not_bare_key(buckets):
    session, s3 = buckets
    m = Manifest(s3, "dstbucket", "cloudtrail/")
    objects = [{"Key": "a.json.gz", "ETag": '"e1"'}]

    # Two different source buckets with an identical bare key must not collide.
    new_from_a = m.filter_new("bucket-a", objects)
    m.mark_processed("s3://bucket-a/a.json.gz", '"e1"', 100, 5, "2026-07-01T00:00:00+00:00")
    new_from_b = m.filter_new("bucket-b", objects)

    assert len(new_from_a) == 1
    assert len(new_from_b) == 1, "bucket-b's identically-keyed file was wrongly treated as already processed"


def test_filter_new_skips_matching_etag_reprocesses_on_change(buckets):
    session, s3 = buckets
    m = Manifest(s3, "dstbucket", "cloudtrail/")
    objects = [{"Key": "a.json.gz", "ETag": '"e1"'}, {"Key": "b.json.gz", "ETag": '"e2"'}]

    assert len(m.filter_new("srcbucket", objects)) == 2
    m.mark_processed("s3://srcbucket/a.json.gz", '"e1"', 100, 5, "2026-07-01T00:00:00+00:00")

    remaining = m.filter_new("srcbucket", objects)
    assert [o["Key"] for o in remaining] == ["b.json.gz"]

    # CloudTrail redelivered "a.json.gz" with different content (new ETag) --
    # should be treated as new again.
    objects[0]["ETag"] = '"e1-changed"'
    remaining2 = m.filter_new("srcbucket", objects)
    assert {o["Key"] for o in remaining2} == {"a.json.gz", "b.json.gz"}


def test_null_etag_entry_is_always_treated_as_already_processed(buckets):
    """Entries produced by `verify --rebuild-manifest` have no ETag (only the
    output was read, not the source) -- is_new() must not treat "unknown ETag"
    as "different, therefore new", or every rebuilt entry would be reprocessed
    on the very next run."""
    session, s3 = buckets
    m = Manifest(s3, "dstbucket", "cloudtrail/")
    m.processed["s3://srcbucket/a.json.gz"] = {
        "etag": None, "size": None, "records": 5, "processed_at": "2026-07-01T00:00:00+00:00",
    }
    assert m.is_new("s3://srcbucket/a.json.gz", '"any-etag-at-all"') is False


def test_save_and_reload_round_trips(buckets):
    session, s3 = buckets
    m = Manifest(s3, "dstbucket", "cloudtrail/")
    m.mark_processed("s3://srcbucket/a.json.gz", '"e1"', 100, 5, "2026-07-01T00:00:00+00:00")
    m.save()

    reloaded = Manifest(s3, "dstbucket", "cloudtrail/")
    assert reloaded.processed == m.processed


def test_backup_returns_none_when_no_existing_manifest(buckets):
    session, s3 = buckets
    m = Manifest(s3, "dstbucket", "cloudtrail/")
    assert m.backup() is None


def test_backup_creates_timestamped_sibling_and_leaves_original_intact(buckets):
    session, s3 = buckets
    m = Manifest(s3, "dstbucket", "cloudtrail/")
    m.mark_processed("s3://srcbucket/a.json.gz", '"e1"', 100, 5, "2026-07-01T00:00:00+00:00")
    m.save()

    backup_key = m.backup()
    assert backup_key is not None
    assert backup_key.startswith("cloudtrail/_manifest/manifest.json.gz.bak-")

    original_still_there = s3.get_object(Bucket="dstbucket", Key=m.key)["Body"].read()
    backup_body = s3.get_object(Bucket="dstbucket", Key=backup_key)["Body"].read()
    assert original_still_there == backup_body


def test_replace_all_swaps_in_memory_state_only(buckets):
    """replace_all() shouldn't itself touch S3 -- save() is a separate,
    explicit step (so a caller can back up first)."""
    session, s3 = buckets
    m = Manifest(s3, "dstbucket", "cloudtrail/")
    m.mark_processed("s3://srcbucket/old.json.gz", '"e1"', 100, 5, "2026-07-01T00:00:00+00:00")
    m.save()

    m.replace_all({"s3://srcbucket/new.json.gz": {"etag": None, "size": None, "records": 9,
                                                    "processed_at": "2026-07-02T00:00:00+00:00"}})
    assert list(m.processed) == ["s3://srcbucket/new.json.gz"]

    # Not yet persisted -- a fresh load should still see the OLD data.
    reloaded = Manifest(s3, "dstbucket", "cloudtrail/")
    assert list(reloaded.processed) == ["s3://srcbucket/old.json.gz"]


def test_save_writes_gzip_compressed_compact_json(buckets):
    session, s3 = buckets
    m = Manifest(s3, "dstbucket", "cloudtrail/")
    m.mark_processed("s3://srcbucket/a.json.gz", '"e1"', 100, 5, "2026-07-01T00:00:00+00:00")
    m.save()

    obj = s3.get_object(Bucket="dstbucket", Key=m.key)
    assert obj.get("ContentEncoding") == "gzip"
    raw = gzip.decompress(obj["Body"].read())
    assert b"\n" not in raw, "expected compact (no-indent) JSON, not pretty-printed"
    assert json.loads(raw)["processed"]["s3://srcbucket/a.json.gz"]["records"] == 5


def test_load_migrates_from_legacy_uncompressed_manifest(buckets):
    """Before compression was added, manifest.json was plain uncompressed
    JSON at this same path minus the .gz suffix. A destination that already
    has one of those (and no manifest.json.gz yet) must still load correctly
    -- and the next save() should write only the new compressed key."""
    session, s3 = buckets
    legacy_body = json.dumps({"processed": {
        "s3://srcbucket/old.json.gz": {"etag": '"e1"', "size": 100, "records": 5,
                                        "processed_at": "2026-07-01T00:00:00+00:00"},
    }}).encode()
    s3.put_object(Bucket="dstbucket", Key="cloudtrail/_manifest/manifest.json", Body=legacy_body)

    m = Manifest(s3, "dstbucket", "cloudtrail/")
    assert m.processed["s3://srcbucket/old.json.gz"]["records"] == 5

    m.save()
    assert s3.get_object(Bucket="dstbucket", Key=m.key)  # new compressed key now exists
    reloaded = Manifest(s3, "dstbucket", "cloudtrail/")
    assert reloaded.processed == m.processed
