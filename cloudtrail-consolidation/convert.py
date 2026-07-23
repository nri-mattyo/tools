"""Core pipeline: list source objects (expanding a wildcard prefix if present)
-> diff against the manifest -> parse each new gzipped CloudTrail file ->
flatten records into the fixed schema -> write partitioned Parquet -> record
the source files as processed.

Kept as plain functions (no classes/framework) so this same module works
unchanged as a local CLI (cli.py) or dropped into a Glue Python Shell job.
"""
import gzip
import json
import logging
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import awswrangler as wr
import pandas as pd
from botocore.config import Config
from botocore.exceptions import ConnectionError, IncompleteReadError, ReadTimeoutError

from athena_ddl import DEFAULT_DATABASE, default_table_name, repair_table_sql
from cloudtrail_schema import ORIG_FILE_COLUMN, PARTITION_COLUMNS, flatten_record, partition_for
from defaults import DEFAULT_BATCH_ROWS, DEFAULT_PROGRESS_INTERVAL, DEFAULT_WORKERS
from manifest import Manifest
from s3url import resolve_prefixes, to_s3_url
from stats import Stats

log = logging.getLogger("convert")


def _repair_partitions(to_session, to_bucket, to_prefix, database, table):
    """Register any new year=/month=/day= partitions this run wrote, via
    MSCK REPAIR TABLE. With a traditional (non-projected) partition scheme,
    this is what makes newly-written data show up in Athena at all -- see
    athena_ddl.py's module docstring for why we're not using partition
    projection here anymore. Logs a warning rather than raising if the table
    doesn't exist yet (e.g. `create-table` hasn't been run against this
    destination), since the actual data write already succeeded and that's
    the more important outcome of this run."""
    database = database or DEFAULT_DATABASE
    table = table or default_table_name(to_prefix)
    sql = repair_table_sql(database, table)
    # Without an explicit s3_output, awswrangler falls back to the
    # unpredictable, account/region-global default results bucket
    # (`aws-athena-query-results-{account}-{region}`) and warns about it on
    # every single call. Point it at a sibling of the manifest instead --
    # same bucket, same "not a data file" convention.
    base = to_prefix if to_prefix.endswith("/") else to_prefix + "/"
    s3_output = f"s3://{to_bucket}/{base}_athena_results/"
    try:
        wr.athena.start_query_execution(sql=sql, database=database, boto3_session=to_session,
                                         s3_output=s3_output, wait=True)
        log.info("repaired partitions for %s.%s", database, table)
    except Exception as e:  # noqa: BLE001 -- a repair failure shouldn't fail an otherwise-successful run
        log.warning("could not repair partitions for %s.%s (%s) -- if the table doesn't exist yet, "
                    "run `create-table` first; new data was still written successfully", database, table, e)


def _cloudtrail_path_parts(key):
    """Pull {region, year, month, day} out of a standard CloudTrail delivery
    path (".../CloudTrail/{region}/{yyyy}/{mm}/{dd}/{...}.json.gz"). Returns
    all-None fields if the key doesn't look like that (chunk_by then just
    falls back to a single group)."""
    parts = key.split("/")
    if "CloudTrail" in parts:
        i = parts.index("CloudTrail")
        if len(parts) > i + 4:
            return {"region": parts[i + 1], "year": parts[i + 2], "month": parts[i + 3], "day": parts[i + 4]}
    return {"region": None, "year": None, "month": None, "day": None}


def _chunk_key(key, chunk_by):
    p = {k: (v or "") for k, v in _cloudtrail_path_parts(key).items()}  # None -> "" so keys stay orderable
    if chunk_by == "date":
        return (p["year"], p["month"], p["day"])
    if chunk_by == "region":
        return p["region"]
    if chunk_by == "region-date":
        return (p["region"], p["year"], p["month"], p["day"])
    return ""  # "none" (or unrecognized): everything is one group


def order_by_chunk(objects, chunk_by):
    """Stable-sort `objects` (list_objects_v2 dicts) by their chunk key so
    same-group files are processed back-to-back, without changing anything
    about which files are in the list."""
    if not chunk_by or chunk_by == "none":
        return objects
    return sorted(objects, key=lambda o: _chunk_key(o["Key"], chunk_by))


def list_source_objects(s3, bucket, prefixes):
    """All .json.gz objects under any of `prefixes` in `bucket`."""
    objects = []
    for prefix in prefixes:
        token = None
        while True:
            kwargs = {"Bucket": bucket, "Prefix": prefix}
            if token:
                kwargs["ContinuationToken"] = token
            resp = s3.list_objects_v2(**kwargs)
            for obj in resp.get("Contents", []):
                if obj["Key"].endswith(".json.gz"):
                    objects.append(obj)
            if not resp.get("IsTruncated"):
                break
            token = resp.get("NextContinuationToken")
    return objects


FETCH_RETRY_ATTEMPTS = 5

# get_object()'s own retries (the pool_config below) only cover the initial
# request/response -- the call returns as soon as headers arrive, and
# Body.read() streams the object content afterward, outside that retry
# wrapper. A stall during the read (seen in practice on a flaky connection)
# raises past it untouched, so the read itself needs its own retry loop.
def fetch_records(s3, bucket, key):
    for attempt in range(1, FETCH_RETRY_ATTEMPTS + 1):
        try:
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            break
        except (ReadTimeoutError, ConnectionError, IncompleteReadError) as e:
            if attempt == FETCH_RETRY_ATTEMPTS:
                raise
            wait = min(2 ** attempt, 30)
            log.warning("retrying %s after body-read error (attempt %d/%d): %s -- waiting %ds",
                        key, attempt, FETCH_RETRY_ATTEMPTS, e, wait)
            time.sleep(wait)
    data = json.loads(gzip.decompress(body))
    return data.get("Records", [])


def _flush(session, rows, bucket, prefix):
    if not rows:
        return
    df = pd.DataFrame(rows)
    start = time.monotonic()
    wr.s3.to_parquet(df=df, path=to_s3_url(bucket, prefix), dataset=True,
                      partition_cols=PARTITION_COLUMNS, mode="append", compression="snappy",
                      boto3_session=session)
    elapsed = time.monotonic() - start
    # Logged explicitly (not inferred from gaps between progress: lines) since
    # the fetch pool sits fully idle for this entire duration -- see
    # "Concurrency" in the README for why that's currently a hard stop, not an
    # approximation.
    log.info("wrote %d rows -> s3://%s/%s (%.1fs, %.0f rows/s)",
              len(rows), bucket, prefix, elapsed, len(rows) / max(elapsed, 1e-9))


def _norm_prefix(prefix):
    return prefix if prefix.endswith("/") or prefix == "" else prefix + "/"


def consolidate(from_session, from_bucket, from_prefix, to_session, to_bucket, to_prefix,
                 filters=(), dry_run=False, batch_rows=DEFAULT_BATCH_ROWS,
                 show_progress=False, progress_interval=DEFAULT_PROGRESS_INTERVAL,
                 workers=DEFAULT_WORKERS, chunk_by=None, database=None, table=None):
    """from_session/to_session are separate boto3 Sessions so source and
    destination can live in different AWS accounts/credentials. filters: list
    of already-imported filter modules (see filters/__init__.py). Returns the
    number of new source files processed.

    The S3 fetch+parse of each new file (the network-bound step) runs on a
    `workers`-sized thread pool. The Parquet write (flush) for each output
    stream (primary + one per filter) runs on its own thread, one write in
    flight per stream at a time, pipelined with fetching the *next* window --
    it no longer blocks the fetch pool for its entire duration. manifest.json
    is still only ever written (and a file only ever marked processed) once
    its corresponding flush is confirmed complete, so there's still exactly
    one writer to it and no locking is needed -- pipelining changed *when*
    that happens, not the safety guarantee. chunk_by (one of CHUNK_BY_CHOICES)
    only reorders the file list before processing -- see order_by_chunk()'s
    docstring.

    Tracks running stats (files processed/skipped, bytes/records read, and
    their throughput rates -- see stats.py) throughout. When show_progress is
    set, a progress line is logged (to stderr, via the "convert" logger) at
    most once per progress_interval seconds; a summary line is always logged
    once at the end regardless of show_progress.

    If this run wrote any new data, MSCK REPAIR TABLE runs at the end against
    database/table (defaulting the same way `create-table` does, from
    DEFAULT_DATABASE and to_prefix) so the new partitions are immediately
    queryable -- see _repair_partitions()."""
    to_prefix = _norm_prefix(to_prefix)
    # Bump the connection pool past its default of 10 so `workers` concurrent
    # GetObjects don't contend for connections (seen as "Connection pool is
    # full, discarding connection" warnings otherwise -- harmless but wasteful,
    # since urllib3 just opens a fresh connection per discard instead of
    # reusing one from the pool). retries=adaptive/10-attempt rides out a
    # flaky connection (e.g. a mobile hotspot prone to brief disconnects)
    # instead of aborting the whole run on one transient timeout.
    pool_config = Config(max_pool_connections=workers + 8,
                          retries={"max_attempts": 10, "mode": "adaptive"})
    from_s3 = from_session.client("s3", config=pool_config)
    # awswrangler's Parquet write (_flush, below) creates its OWN internal S3
    # client rather than one we hand it directly, and its default_botocore_
    # config() *explicitly* sets max_pool_connections=10 -- an explicit value
    # always wins over a session-level set_default_client_config(), so that
    # approach (tried first) silently had no effect. wr.config.botocore_config
    # is the one override awswrangler actually checks before falling back to
    # its own hardcoded default (see its _utils.client(): `botocore_config or
    # default_botocore_config()`), so it's the only thing that reaches
    # awswrangler's internal client. This is a process-global setting, not
    # scoped to to_session -- fine for this CLI's one-run-at-a-time usage.
    wr.config.botocore_config = pool_config
    to_s3 = to_session.client("s3", config=pool_config)

    prefixes = resolve_prefixes(from_s3, from_bucket, from_prefix)
    log.info("resolved %d source prefix(es) under s3://%s/%s", len(prefixes), from_bucket, from_prefix)

    objects = list_source_objects(from_s3, from_bucket, prefixes)
    if not objects:
        # Loading manifest.json is pure waste with nothing to diff it against
        # -- and on a destination with a large manifest, that GET alone can
        # take tens of seconds (seen in practice: ~20s for a run that found 0
        # source files under the given prefix). Skip it entirely.
        log.info("no source files found under s3://%s/%s -- nothing to do", from_bucket, from_prefix)
        return 0
    manifest = Manifest(to_s3, to_bucket, to_prefix)
    new_objects = manifest.filter_new(from_bucket, objects)
    log.info("%d/%d source files are new (unprocessed)", len(new_objects), len(objects))

    if dry_run:
        for obj in new_objects:
            print(f"s3://{from_bucket}/{obj['Key']}")
        return len(new_objects)

    new_objects = order_by_chunk(new_objects, chunk_by)
    # Stats' clock starts here, not before -- listing + manifest diffing above
    # can itself take tens of seconds on a big destination, and that has
    # nothing to do with per-record processing throughput. Including it would
    # make bytes_per_sec/lines_per_sec (especially early in a run, before
    # there's enough processed volume to dilute a fixed startup cost) look
    # artificially worse than the run actually is.
    stats = Stats()
    stats.skip(len(objects) - len(new_objects))

    primary_rows = []
    # (orig_file, etag, size, count, processed_at) for files whose rows are
    # sitting in primary_rows (or were, until the flush covering them was
    # submitted) but aren't yet safe to mark processed -- see
    # settle_pending_flush().
    pending_entries = []
    pending_flush = None          # in-flight Future for the primary destination
    pending_flush_entries = []    # entries pending_flush covers, once it completes

    filter_rows = {f.SUBPATH: [] for f in filters}
    pending_filter_flush = {f.SUBPATH: None for f in filters}

    processed_at = datetime.now(timezone.utc).isoformat()
    last_progress = time.monotonic()

    def settle_pending_flush():
        """Wait for the in-flight primary flush (if any), then mark its files
        processed and persist manifest.json. Must run before a file's entry
        is ever committed -- otherwise, since fetching the *next* batch now
        overlaps with writing the *current* one, a crash mid-write could let
        manifest.json claim a file "done" whose rows were never actually
        written (the exact failure mode as the earlier concurrent-run
        incident, just self-inflicted by pipelining instead of a second
        process)."""
        nonlocal pending_flush, pending_flush_entries
        if pending_flush is not None:
            pending_flush.result()  # blocks only if fetching outpaced the write; propagates write errors
            for orig_file, etag, size, count, ts in pending_flush_entries:
                manifest.mark_processed(orig_file, etag, size, count, ts)
            manifest.save()
            pending_flush = None
            pending_flush_entries = []

    # Fetch+parse (S3 GetObject, gunzip, json.loads -- I/O- and C-level work
    # that releases the GIL) run concurrently across `workers` threads. This
    # is windowed (not one pool.map over the whole file list) so memory stays
    # bounded to one window's worth of parsed records at a time, same as the
    # batch_rows flush threshold already bounds it -- a run over thousands of
    # files shouldn't need to hold all of them in memory just to get
    # concurrency on the fetch step.
    #
    # The Parquet write (_flush) runs on its own small pool (one slot per
    # output stream: primary + one per filter) so it overlaps with fetching
    # the *next* window instead of blocking it -- previously the fetch pool
    # sat fully idle for the entire duration of every write. At most one
    # write per output stream is ever in flight (settle_pending_flush /
    # prev.result() below wait for the previous one before starting another),
    # so writes to the same destination never race each other.
    window_size = workers * 4
    with ThreadPoolExecutor(max_workers=1 + len(filters)) as write_pool, \
         ThreadPoolExecutor(max_workers=workers) as pool:
        for window_start in range(0, len(new_objects), window_size):
            window = new_objects[window_start:window_start + window_size]
            window_records = pool.map(lambda o: fetch_records(from_s3, from_bucket, o["Key"]), window)

            for obj, records in zip(window, window_records):
                key = obj["Key"]
                orig_file = to_s3_url(from_bucket, key)
                count = 0
                for record in records:
                    event_time = record.get("eventTime")
                    if not event_time:
                        log.warning("skipping record with no eventTime in %s", key)
                        continue
                    row = flatten_record(record)
                    row.update(partition_for(event_time))
                    row[ORIG_FILE_COLUMN] = orig_file
                    primary_rows.append(row)
                    count += 1
                    for f in filters:
                        if f.matches(record):
                            filter_rows[f.SUBPATH].append(dict(row))
                pending_entries.append((orig_file, obj["ETag"], obj.get("Size"), count, processed_at))
                stats.record_file(obj.get("Size"), count)

                if show_progress and time.monotonic() - last_progress >= progress_interval:
                    log.info(stats.progress_line())
                    last_progress = time.monotonic()

                if len(primary_rows) >= batch_rows:
                    settle_pending_flush()  # wait for the previous write, commit its entries
                    pending_flush = write_pool.submit(_flush, to_session, primary_rows, to_bucket, to_prefix)
                    pending_flush_entries = pending_entries
                    primary_rows = []
                    pending_entries = []
                for subpath, rows in filter_rows.items():
                    if len(rows) >= batch_rows:
                        prev = pending_filter_flush[subpath]
                        if prev is not None:
                            prev.result()
                        pending_filter_flush[subpath] = write_pool.submit(
                            _flush, to_session, rows, to_bucket, to_prefix + subpath)
                        filter_rows[subpath] = []

        # Drain: commit whatever the loop left in flight, submit any leftover
        # rows (including files that contributed zero rows -- pending_entries
        # can be non-empty even with primary_rows empty, e.g. a trailing run
        # of skipped-for-no-eventTime files; _flush() no-ops on empty rows but
        # settle_pending_flush() still needs to run to commit their entries),
        # then wait for that final round too.
        settle_pending_flush()
        if primary_rows or pending_entries:
            pending_flush = write_pool.submit(_flush, to_session, primary_rows, to_bucket, to_prefix)
            pending_flush_entries = pending_entries
        for subpath, rows in filter_rows.items():
            if rows:
                prev = pending_filter_flush[subpath]
                if prev is not None:
                    prev.result()
                pending_filter_flush[subpath] = write_pool.submit(
                    _flush, to_session, rows, to_bucket, to_prefix + subpath)
        settle_pending_flush()
        for f in pending_filter_flush.values():
            if f is not None:
                f.result()

    log.info(stats.summary_line())
    if new_objects:
        _repair_partitions(to_session, to_bucket, to_prefix, database, table)
    return len(new_objects)
