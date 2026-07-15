"""convert.py: the core consolidate() pipeline -- correctness, dedup,
batch-boundary/file-atomicity, the pipelined-flush safety invariant, and
chunk-by ordering. These formalize what was verified ad hoc against moto
throughout the session that built this tool."""
import io
import logging
from collections import Counter

import pyarrow.parquet as pq
import pytest

import convert
import manifest as manifest_mod
from filters import load_filter
from conftest import cloudtrail_key, cloudtrail_record, put_cloudtrail_file


def _read_column(s3, bucket, key, column):
    data = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    return pq.read_table(io.BytesIO(data), columns=[column]).column(column).to_pylist()


def _all_primary_rows(s3, bucket, prefix, column):
    resp = s3.list_objects_v2(Bucket=bucket, Prefix=f"{prefix}year=")
    values = []
    for obj in resp.get("Contents", []):
        values.extend(_read_column(s3, bucket, obj["Key"], column))
    return values


def test_basic_consolidate_produces_correct_rows_and_partitions(buckets):
    session, s3 = buckets
    key = cloudtrail_key()
    put_cloudtrail_file(s3, "srcbucket", key, [
        cloudtrail_record(eventID="1", eventTime="2026-07-01T10:00:00Z"),
        cloudtrail_record(eventID="2", eventTime="2026-07-01T11:00:00Z", eventName="RunInstances"),
    ])

    n = convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                             session, "dstbucket", "cloudtrail/", workers=2)
    assert n == 1

    resp = s3.list_objects_v2(Bucket="dstbucket", Prefix="cloudtrail/year=2026/month=202607/day=20260701/")
    assert len(resp.get("Contents", [])) == 1
    ids = _all_primary_rows(s3, "dstbucket", "cloudtrail/", "eventid")
    assert sorted(ids) == ["1", "2"]


def test_orig_file_column_is_the_full_source_url(buckets):
    session, s3 = buckets
    key = cloudtrail_key(name="file")
    put_cloudtrail_file(s3, "srcbucket", key, [cloudtrail_record(eventID="1")])
    convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                         session, "dstbucket", "cloudtrail/", workers=1)
    orig_files = _all_primary_rows(s3, "dstbucket", "cloudtrail/", "orig_file")
    assert orig_files == [f"s3://srcbucket/{key}"]


def test_boolean_fields_serialize_as_lowercase_strings(buckets):
    """Regression test: Python's str(True) is "True", but CloudTrail's own
    JSON convention (and Athena queries like WHERE readonly='false') expects
    lowercase "true"/"false"."""
    session, s3 = buckets
    key = cloudtrail_key()
    put_cloudtrail_file(s3, "srcbucket", key, [
        cloudtrail_record(eventID="1", readOnly=True),
        cloudtrail_record(eventID="2", readOnly=False),
    ])
    convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                         session, "dstbucket", "cloudtrail/", workers=1)
    values = _all_primary_rows(s3, "dstbucket", "cloudtrail/", "readonly")
    assert set(values) == {"true", "false"}


def test_rerun_finds_nothing_new_and_produces_no_duplicates(buckets):
    session, s3 = buckets
    key = cloudtrail_key()
    put_cloudtrail_file(s3, "srcbucket", key, [cloudtrail_record(eventID="1")])
    from_prefix = "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/"

    n1 = convert.consolidate(session, "srcbucket", from_prefix, session, "dstbucket", "cloudtrail/", workers=1)
    n2 = convert.consolidate(session, "srcbucket", from_prefix, session, "dstbucket", "cloudtrail/", workers=1)
    assert n1 == 1
    assert n2 == 0
    assert len(_all_primary_rows(s3, "dstbucket", "cloudtrail/", "eventid")) == 1


def test_wildcard_across_regions_and_dates_is_complete_and_dedup_safe(buckets):
    session, s3 = buckets
    regions = ["us-east-1", "us-west-2", "eu-west-1"]
    days = ["01", "02"]
    expected_ids = set()
    for region in regions:
        for day in days:
            for i in range(5):
                eid = f"{region}-{day}-{i}"
                expected_ids.add(eid)
                key = cloudtrail_key(region=region, date=f"2026/07/{day}", name=f"f{i}")
                put_cloudtrail_file(s3, "srcbucket", key, [
                    cloudtrail_record(eventID=eid, awsRegion=region, eventTime=f"2026-07-{day}T10:00:00Z"),
                ])

    n = convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/*/2026/07/",
                             session, "dstbucket", "cloudtrail/", workers=4, batch_rows=7)
    assert n == len(expected_ids)

    got_ids = _all_primary_rows(s3, "dstbucket", "cloudtrail/", "eventid")
    assert len(got_ids) == len(expected_ids), "row count mismatch -- some records lost or duplicated"
    assert len(set(got_ids)) == len(got_ids), "duplicate eventids found"
    assert set(got_ids) == expected_ids


@pytest.mark.parametrize("chunk_by", ["none", "date", "region", "region-date"])
def test_a_single_file_is_never_split_across_two_flushes(buckets, chunk_by):
    """batch_rows is a soft/minimum threshold: the loop only checks it once
    per file, after that file's entire record set is already appended. A
    10+10-row pair with batch_rows=15 must land as one 20-row batch, not a
    15/5 split -- this holds regardless of chunk_by, since chunking only
    reorders which files come first."""
    session, s3 = buckets
    for fname, n in [("fileA", 10), ("fileB", 10)]:
        records = [cloudtrail_record(eventID=f"{fname}-{i}") for i in range(n)]
        put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(name=fname), records)

    seen_batches = []
    orig_flush = convert._flush

    def spy_flush(sess, rows, bucket, prefix):
        if rows:
            seen_batches.append(Counter(r["orig_file"].rsplit("/", 1)[-1].replace(".json.gz", "") for r in rows))
        return orig_flush(sess, rows, bucket, prefix)

    convert._flush = spy_flush
    try:
        convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                             session, "dstbucket", "cloudtrail/", workers=1, batch_rows=15, chunk_by=chunk_by)
    finally:
        convert._flush = orig_flush

    for batch in seen_batches:
        for fname, count in batch.items():
            assert count == 10, f"{fname} was split across batches (only {count}/10 rows in one flush)"


def test_write_failure_does_not_mark_manifest_processed(buckets):
    """The critical safety invariant for pipelined fetch+flush: a batch's
    files are only ever marked processed in manifest.json once that batch's
    flush is CONFIRMED complete. If a write fails outright, none of its
    files' entries should reach the persisted manifest -- otherwise a retry
    would skip files whose data was never actually written."""
    session, s3 = buckets
    for i in range(15):
        put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(name=f"file{i:02d}"),
                             [cloudtrail_record(eventID=str(i))])

    orig_flush = convert._flush
    call_count = {"n": 0}

    def flaky_flush(sess, rows, bucket, prefix):
        call_count["n"] += 1
        if call_count["n"] == 2 and rows:
            raise RuntimeError("simulated write failure")
        return orig_flush(sess, rows, bucket, prefix)

    convert._flush = flaky_flush
    try:
        with pytest.raises(RuntimeError, match="simulated write failure"):
            convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                                 session, "dstbucket", "cloudtrail/", workers=4, batch_rows=5)
    finally:
        convert._flush = orig_flush

    m = manifest_mod.Manifest(s3, "dstbucket", "cloudtrail/")
    first_batch = {f"s3://srcbucket/{cloudtrail_key(name=f'file{i:02d}')}" for i in range(5)}
    second_batch = {f"s3://srcbucket/{cloudtrail_key(name=f'file{i:02d}')}" for i in range(5, 10)}
    assert set(m.processed) == first_batch
    assert not (set(m.processed) & second_batch), "manifest claims files done whose write failed"


def test_zero_row_trailing_files_are_still_committed_to_manifest(buckets):
    """A file whose records all lack eventTime (skipped, contributes 0 rows)
    must still end up in the manifest, or it gets uselessly refetched on
    every future run forever."""
    session, s3 = buckets
    put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(name="good"), [cloudtrail_record(eventID="1")])
    put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(name="empty"), [{"eventVersion": "1.08", "eventName": "X"}])

    from_prefix = "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/"
    n1 = convert.consolidate(session, "srcbucket", from_prefix, session, "dstbucket", "cloudtrail/",
                              workers=2, batch_rows=100)
    n2 = convert.consolidate(session, "srcbucket", from_prefix, session, "dstbucket", "cloudtrail/",
                              workers=2, batch_rows=100)
    assert n1 == 2
    assert n2 == 0, "the zero-row file was not committed to the manifest and got refetched"


def test_filters_write_correct_subsets_to_their_own_subpaths(buckets):
    session, s3 = buckets
    key = cloudtrail_key()
    put_cloudtrail_file(s3, "srcbucket", key, [
        cloudtrail_record(eventID="1", readOnly=True),  # neither filter
        cloudtrail_record(eventID="2", eventSource="s3.amazonaws.com", eventName="GetObject",
                           eventCategory="Data", readOnly=True),  # s3_data_events only
        cloudtrail_record(eventID="3", eventName="TerminateInstances", readOnly=False),  # errors_and_writes only
    ])

    filters = [load_filter("filters.errors_and_writes"), load_filter("filters.s3_data_events")]
    convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                         session, "dstbucket", "cloudtrail/", filters=filters, workers=1)

    ew_ids = _all_primary_rows(s3, "dstbucket", "cloudtrail/errors_and_writes/", "eventid")
    s3d_ids = _all_primary_rows(s3, "dstbucket", "cloudtrail/s3_data_events/", "eventid")
    assert ew_ids == ["3"]
    assert s3d_ids == ["2"]
    # Primary dataset always has everything, filters or no filters.
    assert sorted(_all_primary_rows(s3, "dstbucket", "cloudtrail/", "eventid")) == ["1", "2", "3"]


def test_dry_run_lists_new_files_without_writing_anything(buckets, capsys):
    session, s3 = buckets
    put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(), [cloudtrail_record(eventID="1")])

    n = convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                             session, "dstbucket", "cloudtrail/", dry_run=True)
    assert n == 1
    printed = capsys.readouterr().out
    assert "s3://srcbucket/" in printed

    resp = s3.list_objects_v2(Bucket="dstbucket", Prefix="cloudtrail/")
    assert "Contents" not in resp, "dry-run must not write any data"


def test_zero_source_files_short_circuits_without_loading_manifest(buckets, caplog):
    """Loading manifest.json is pure waste with nothing to diff it against --
    and on a destination with a large manifest, that GET alone can take tens
    of seconds. consolidate() must return early before ever constructing a
    Manifest when the source listing comes back empty."""
    session, s3 = buckets
    # No files put in srcbucket at all -- source prefix is empty.

    guard_tripped = {"value": False}
    orig_init = manifest_mod.Manifest.__init__

    def guard(self, *a, **kw):
        guard_tripped["value"] = True
        return orig_init(self, *a, **kw)

    manifest_mod.Manifest.__init__ = guard
    try:
        with caplog.at_level(logging.INFO):
            n = convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                                     session, "dstbucket", "cloudtrail/", workers=2)
    finally:
        manifest_mod.Manifest.__init__ = orig_init

    assert n == 0
    assert guard_tripped["value"] is False, "Manifest was constructed despite zero source files"
    assert any("nothing to do" in r.message for r in caplog.records)


def _spy_on_repair(monkeypatch):
    """Swap out wr.athena.start_query_execution with a spy that records every
    call's `sql`/`database`, without touching real Athena. Returns the list
    of calls (each a dict)."""
    import awswrangler as wr
    calls = []

    def fake_start_query_execution(sql, database, boto3_session=None, s3_output=None, wait=None):
        calls.append({"sql": sql, "database": database})

    monkeypatch.setattr(wr.athena, "start_query_execution", fake_start_query_execution)
    return calls


def test_successful_run_repairs_partitions_for_the_derived_table(buckets, monkeypatch):
    session, s3 = buckets
    calls = _spy_on_repair(monkeypatch)
    put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(), [cloudtrail_record(eventID="1")])

    n = convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                             session, "dstbucket", "cloudtrail/", workers=1)
    assert n == 1
    assert calls == [{"sql": "MSCK REPAIR TABLE cloudtrail_logs.cloudtrail;", "database": "cloudtrail_logs"}]


def test_custom_database_and_table_are_used_for_repair(buckets, monkeypatch):
    session, s3 = buckets
    calls = _spy_on_repair(monkeypatch)
    put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(), [cloudtrail_record(eventID="1")])

    convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                         session, "dstbucket", "cloudtrail/", workers=1,
                         database="my_db", table="my_table")
    assert calls == [{"sql": "MSCK REPAIR TABLE my_db.my_table;", "database": "my_db"}]


def test_no_repair_when_nothing_new_was_processed(buckets, monkeypatch):
    session, s3 = buckets
    calls = _spy_on_repair(monkeypatch)
    put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(), [cloudtrail_record(eventID="1")])
    from_prefix = "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/"

    convert.consolidate(session, "srcbucket", from_prefix, session, "dstbucket", "cloudtrail/", workers=1)
    calls.clear()  # only care about the re-run below

    n2 = convert.consolidate(session, "srcbucket", from_prefix, session, "dstbucket", "cloudtrail/", workers=1)
    assert n2 == 0
    assert calls == [], "repair should not run when consolidate found nothing new to process"


def test_repair_failure_logs_a_warning_but_does_not_fail_the_run(buckets, monkeypatch, caplog):
    """The data write already succeeded by the time repair runs -- a repair
    failure (e.g. the Athena table doesn't exist yet) shouldn't take down an
    otherwise-successful consolidate run."""
    session, s3 = buckets
    put_cloudtrail_file(s3, "srcbucket", cloudtrail_key(), [cloudtrail_record(eventID="1")])

    import awswrangler as wr

    def failing_start_query_execution(sql, database, boto3_session=None, wait=None):
        raise Exception("TABLE_NOT_FOUND: cloudtrail_logs.cloudtrail")

    monkeypatch.setattr(wr.athena, "start_query_execution", failing_start_query_execution)

    with caplog.at_level(logging.WARNING):
        n = convert.consolidate(session, "srcbucket", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
                                 session, "dstbucket", "cloudtrail/", workers=1)

    assert n == 1, "the run itself must still report success despite the repair failure"
    assert any("could not repair partitions" in r.message for r in caplog.records)
