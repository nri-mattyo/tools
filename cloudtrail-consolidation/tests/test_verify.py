"""verify.py: reading back actual durable counts from the Parquet data,
diffing against manifest.json, and --rebuild-manifest's backup+replace flow."""
import manifest as manifest_mod
from conftest import cloudtrail_key, cloudtrail_record, put_cloudtrail_file

import convert
import verify as verify_mod
from filters import load_filter


def test_clean_manifest_reports_no_issues(buckets):
    session, s3 = buckets
    for i in range(5):
        put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(name=f"file{i}"), [cloudtrail_record(eventID=str(i))])
    convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                         session, "dstbucket", "cloudtrail/", workers=2)

    report = verify_mod.verify(session, "dstbucket", "cloudtrail/", rebuild=False)
    assert report["manifest_entries"] == 5
    assert report["distinct_files_in_data"] == 5
    assert report["total_rows_in_data"] == 5
    assert report["mismatched"] == []
    assert report["missing_from_manifest"] == []


def test_detects_count_mismatch_and_missing_entry(buckets):
    session, s3 = buckets
    for i in range(5):
        put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(name=f"file{i}"), [cloudtrail_record(eventID=str(i))])
    convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                         session, "dstbucket", "cloudtrail/", workers=2)

    m = manifest_mod.Manifest(s3, "dstbucket", "cloudtrail/")
    victim, dropped = list(m.processed)[:2]
    m.processed[victim]["records"] = 999
    del m.processed[dropped]
    m.save()

    report = verify_mod.verify(session, "dstbucket", "cloudtrail/", rebuild=False)
    assert report["mismatched"] == [(victim, 999, 1)]
    assert report["missing_from_manifest"] == [dropped]


def test_rebuild_manifest_backs_up_then_replaces(buckets):
    session, s3 = buckets
    for i in range(5):
        put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(name=f"file{i}"), [cloudtrail_record(eventID=str(i))])
    convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                         session, "dstbucket", "cloudtrail/", workers=2)

    m = manifest_mod.Manifest(s3, "dstbucket", "cloudtrail/")
    m.processed[next(iter(m.processed))]["records"] = 999  # introduce drift
    m.save()

    verify_mod.verify(session, "dstbucket", "cloudtrail/", rebuild=True)

    backups = [o["Key"] for o in s3.list_objects_v2(Bucket="dstbucket", Prefix="cloudtrail/_manifest/")["Contents"]
               if ".bak-" in o["Key"]]
    assert len(backups) == 1

    rebuilt = manifest_mod.Manifest(s3, "dstbucket", "cloudtrail/")
    assert len(rebuilt.processed) == 5
    assert all(entry["etag"] is None for entry in rebuilt.processed.values())
    assert all(entry["records"] == 1 for entry in rebuilt.processed.values())

    # And a fresh verify against the rebuilt manifest should now be clean.
    report = verify_mod.verify(session, "dstbucket", "cloudtrail/", rebuild=False)
    assert report["mismatched"] == []
    assert report["missing_from_manifest"] == []


def test_rebuild_with_no_prior_manifest_creates_no_backup(buckets):
    session, s3 = buckets
    put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(), [cloudtrail_record(eventID="1")])
    convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                         session, "dstbucket", "cloudtrail/", workers=1)

    # Delete the manifest that consolidate() just wrote, to simulate rebuilding
    # from a completely bare destination.
    m = manifest_mod.Manifest(s3, "dstbucket", "cloudtrail/")
    s3.delete_object(Bucket="dstbucket", Key=m.key)

    verify_mod.verify(session, "dstbucket", "cloudtrail/", rebuild=True)
    objs = s3.list_objects_v2(Bucket="dstbucket", Prefix="cloudtrail/_manifest/").get("Contents", [])
    backups = [o for o in objs if ".bak-" in o["Key"]]
    assert backups == []
    assert any(o["Key"].endswith("manifest.json.gz") for o in objs), "rebuild should still produce a fresh manifest"


def test_filter_subpaths_are_excluded_from_verification(buckets):
    """Filters only ever hold a subset of the primary data by design --
    mixing their files into the primary count would understate/miscount."""
    session, s3 = buckets
    key = cloudtrail_key()
    put_cloudtrail_file(s3, "srcbucket", key, [
        cloudtrail_record(eventID="1", readOnly=True),
        cloudtrail_record(eventID="2", readOnly=False),  # matches errors_and_writes
        cloudtrail_record(eventID="3", readOnly=False),  # matches errors_and_writes
    ])
    filters = [load_filter("filters.errors_and_writes")]
    convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                         session, "dstbucket", "cloudtrail/", filters=filters, workers=1)

    # Sanity: the filter really did write something separate to verify against.
    filter_objs = s3.list_objects_v2(Bucket="dstbucket", Prefix="cloudtrail/errors_and_writes/").get("Contents", [])
    assert len(filter_objs) > 0

    report = verify_mod.verify(session, "dstbucket", "cloudtrail/", rebuild=False)
    assert report["total_rows_in_data"] == 3, "filter subpath rows leaked into the primary verification count"
    assert report["mismatched"] == []
    assert report["missing_from_manifest"] == []


def test_actual_counts_returns_empty_for_a_destination_with_no_data(buckets):
    session, s3 = buckets
    assert verify_mod.actual_counts(session, "dstbucket", "cloudtrail/") == {}
