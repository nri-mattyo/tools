# cloudtrail-consolidation

Merges raw per-region CloudTrail `.json.gz` delivery files into partitioned
Parquet (`year=yyyy/month=yyyymm/day=yyyymmdd/`), keeps a manifest of what's
already been merged so re-runs are incremental, and can register/refresh the
Athena table over the result. Optional filters produce derivative datasets
(e.g. errors + write ops only) in the same run, same layout.

Runs as a plain CLI today; `convert.py` has no CLI-specific code so it drops
into a Glue Python Shell job unchanged (see `aws/`) if/when you want it
scheduled.

## Why not Glue Spark or Athena CTAS

- **Glue Spark ETL** (the common pattern for this) pays for real cluster
  startup (~1 min cold start) and DPU-minute billing, and Spark/CTAS SQL is
  awkward for per-file manifest dedup and per-record filtering -- overkill for
  incremental runs over a modest daily file count.
- **Athena CTAS** is great for one-time bulk backfills, but it selects by S3
  prefix/partition, not an arbitrary "files I haven't seen yet" list, so it
  doesn't fit manifest-tracked incremental processing without an extra staging
  step.

Instead: boto3 + [awswrangler](https://aws-sdk-pandas.readthedocs.io/) do the
list/parse/write, an S3-resident `manifest.json` tracks dedup state, and the
Athena table's partitions are real Glue Catalog entries kept current via
`MSCK REPAIR TABLE`, run automatically after every `consolidate` run that
writes new data (see "Athena schema" below for why this isn't partition
projection).

## Install

```bash
pip install -r requirements.txt
```

## Usage

```bash
buckets=(
 s3://aws-cloudtrail-logs-381492092437-74dbd159/AWSLogs/381492092437/CloudTrail/           # --from-profile nri-develop
 s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/AWSLogs/381492092437/CloudTrail/    # --from-profile nri-develop
 s3://nri-cloudtrail-logs-637423466983/cloudtrail-logs/AWSLogs/637423466983/CloudTrail/    # --from-profile nri-customer
 s3://aws-cloudtrail-logs-293034550673-c21dd2f3/AWSLogs/293034550673/CloudTrail/           # --from-profile newton
)

# Merge one day, all regions (the '*' expands to every region prefix found
# under CloudTrail/ via list_objects_v2 + Delimiter="/"):
python cli.py consolidate --profile my-profile \
  --from s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/AWSLogs/381492092437/CloudTrail/*/2026/07/01/ \
  --to   s3://my-consolidated-bucket/cloudtrail/

# A whole month, same wildcard, one level up:
python cli.py consolidate --profile my-profile \
  --from s3://nri-cloudtrail-logs-381492092437/cloudtrail-logs/AWSLogs/381492092437/CloudTrail/*/2026/07/ \
  --to   s3://my-consolidated-bucket/cloudtrail/

# See what would be processed without writing anything:
python cli.py consolidate --from ... --to ... --dry-run

# Also split out errors/write-ops and S3 data-events into their own datasets
# (same partitioned-Parquet layout, under --to's prefix + the filter's SUBPATH):
python cli.py consolidate --from ... --to ... \
  --filter filters.errors_and_writes --filter filters.s3_data_events

# Print (or --execute) the Athena CREATE TABLE DDL for a destination:
python cli.py create-table --to s3://my-consolidated-bucket/cloudtrail/ --execute
```

`--profile` / `AWS_PROFILE` both work. `--from`/`--to` accept a full `s3://`
URL, or `--from-bucket`/`--from-prefix` (and `--to-bucket`/`--to-prefix`)
given separately.

Only one `/*/` wildcard segment is supported (matches every example above --
the region slot). A second wildcard raises `NotImplementedError` rather than
guessing.

## Progress and stats

Every real run (not `--dry-run`) tracks `files_processed`, `files_skipped`
(already in the manifest), `bytes_processed` and `lines_processed` (records),
and the resulting `bytes_per_sec`/`lines_per_sec`. A `summary:` line with all
of these is always logged once at the end, to stderr, regardless of any flag.
Pass `--progress` to also get a `progress:` line logged periodically (every 5
seconds) while the run is in flight, useful for watching a large backfill:

```
INFO convert: progress: files_processed=1204 files_skipped=87 bytes_processed=284918233 lines_processed=241823 bytes_per_sec=11390512 lines_per_sec=9678
...
INFO convert: summary: files_processed=8931 files_skipped=87 bytes_processed=2109482013 lines_processed=2043995 elapsed_sec=974.2 avg_bytes_per_sec=2165482 avg_lines_per_sec=2098
```

`files_skipped` reflects the manifest dedup count from "How dedup works"
below, so a healthy re-run against a destination you've already populated
should show `files_processed=0` and `files_skipped` equal to the full file
count.

## Concurrency

Each new file's S3 fetch + gunzip + JSON parse (the network-bound step) runs
on a thread pool (`--workers`, default 16) -- this is what actually makes a
run faster, since the fully-serial original version spent almost all its wall
clock waiting on one `GetObject` round-trip at a time.

```bash
python cli.py consolidate --workers 32 --from ... --to ...
```

The Parquet write (flush) for each output stream (the primary destination,
plus one per `--filter`) runs on its own thread and is **pipelined** with
fetching the *next* window of files -- earlier versions had the fetch pool
sit fully idle for the entire duration of every flush (which, on a run
touching many partitions, can be tens of seconds), capping throughput no
amount of `--workers` could get past. At most one write per output stream is
ever in flight at a time. `manifest.json` is still only ever written -- and a
file only ever marked processed -- once its corresponding flush is *confirmed
complete*; pipelining changed when that commit happens (it can now lag one
batch behind, since fetching may have already moved on), not the guarantee
that a file is never marked done before its data is durably written. If a
flush fails outright, the run stops (the exception propagates) and only
already-committed batches are in the manifest -- nothing is marked done
without its write having actually succeeded.

`--chunk-by {none,date,region,region-date}` reorders the (already-deduped)
file list before processing -- e.g. `region` processes every file for one
region before moving to the next, `region-date` groups by region then date.
This is purely for experimenting with throughput (e.g. a broad multi-month
run touches far fewer distinct day partitions per flush if sorted by date
first, which shrinks how much of that per-flush time pipelining even needs to
hide); it does not change what gets written, only the order files are
processed in and how the accumulated batch happens to be distributed across
partitions when a flush fires.

`--batch-size` (default 200000) controls how many rows accumulate in memory
before a flush -- with pipelining, memory pressure is the main reason not to
push this arbitrarily high (there's no other downside from raising it if you
have the RAM):

```bash
python cli.py consolidate --batch-size 1000000 --chunk-by date --workers 32 --from ... --to ...
```

boto3's default connection pool (10) is sized for one thread's worth of
traffic, so both the read side (`--from`) and write side (`--to`) get their
pool bumped to `workers + 8`. The write side needs its own explicit handling:
`awswrangler`'s Parquet upload creates its own internal S3 client rather than
one we hand it directly, and that client's default config *explicitly* sets
`max_pool_connections=10` -- an explicitly-set value always wins over a
session-level override, so the pool size has to be set via the global
`wr.config.botocore_config`, the one override `awswrangler` actually checks
before falling back to its own hardcoded default. Without this you'd see
occasional (harmless, but wasteful -- urllib3 just opens a fresh connection
instead of reusing a pooled one) `Connection pool is full, discarding
connection` warnings, usually clustered right around Parquet flushes.

```bash
python cli.py consolidate --chunk-by region-date --batch-size 50000 --from ... --to ...
```

## Reading and writing with different credentials

Source and destination can live in different AWS accounts/profiles (e.g.
reading each account's own CloudTrail bucket, writing to a shared analytics
account):

```bash
python cli.py consolidate \
  --from-profile source-account --to-profile analytics-account \
  --from s3://source-account-bucket/AWSLogs/.../CloudTrail/*/2026/07/01/ \
  --to   s3://analytics-account-bucket/cloudtrail/
```

`--from-profile`/`AWS_FROM_PROFILE` and `--to-profile`/`AWS_TO_PROFILE` each
override `--profile`/`AWS_PROFILE` for just that side; plain `--profile` (or
`AWS_PROFILE`) is used for both sides when the more specific ones aren't set.
Cross-account access still needs the destination bucket's policy (or the
source bucket's, depending on direction) to actually permit it -- this only
controls which local credentials the tool signs requests with.

## Don't run two instances against the same destination at once

There's no locking on `manifest.json` (see "How dedup works" below) -- two
concurrent runs against the same `--to` will both list the same "new" files,
both write them, and the loser's final manifest save simply overwrites the
winner's, leaving the destination with duplicated rows and a manifest that no
longer matches what's actually there. This is easy to trigger by accident if
you background a run yourself (e.g. a trailing `&`) on top of a harness/tool
that *also* backgrounds it -- the process can keep running undetected after
you think you've stopped it. If you're not sure whether a previous run against
a destination is still alive, check for it before starting a new one rather
than assuming.

## How dedup works

`manifest.json.gz` lives at
`s3://<to-bucket>/<to-prefix>_manifest/manifest.json.gz` (a sibling of the
data, not inside a partition, so Athena/Glue never see it as a data file).
Each source file is recorded by its **full `s3://bucket/key`** (matching the
`orig_file` column every row carries -- see "Athena schema" below), not just
the bare key -- this matters as soon as more than one source bucket feeds the
same destination (a real, expected setup: several accounts' CloudTrail
buckets consolidated into one analytics bucket), since two different buckets
can otherwise have identically-shaped keys with no way to tell them apart.
Each entry also records its ETag; a re-run only processes files that are
either new or whose ETag has changed (rare, but CloudTrail can redeliver).
The manifest is saved after every ~200k-row batch during a run (not just at
the end), so a crash partway through a large backfill only risks
re-processing files since the last save, not the whole run -- because writes
are append-only Parquet, a re-processed file's rows get appended again rather
than silently lost, at worst causing a small amount of duplication you'd need
to be aware of if a run is interrupted and re-run without checking why it
died.

The manifest is gzip-compressed and written with compact (no-indent) JSON --
at real scale (millions of source files) this is a ~370MB document
uncompressed, ~53MB gzipped, and every run downloads, parses, and re-uploads
it whole just to diff "is this file new" against it, so its size on the wire
directly drives per-run overhead. A destination with an older, pre-compression
`manifest.json` (no `.gz`) is migrated transparently on next load -- read once
from the legacy uncompressed key if no `manifest.json.gz` exists yet, then
only the compressed key is ever written going forward. The old uncompressed
key isn't deleted automatically; clean it up by hand once you've confirmed the
new one is in place.

If the source listing (after wildcard expansion) comes back with **zero**
files -- e.g. a `--from` scoped to a date range with nothing delivered yet --
the manifest is never loaded at all. On a destination with a large manifest
that GET can itself take real time, which would otherwise be wasted work for
a run that has nothing to diff it against anyway.

## Verifying durability

`manifest.json` marks a file processed only once its batch's Parquet write is
*confirmed complete* (see "Concurrency" above) -- but that still relies on
`awswrangler` returning without raising, and on this tool's own in-memory
bookkeeping of which files went into which batch being correct. `verify`
closes that loop by reading back what's actually sitting in S3 and comparing
it against the manifest, instead of trusting either of those:

```bash
python cli.py verify --to s3://my-consolidated-bucket/cloudtrail/ --to-profile my-profile
```

This reads back just the `orig_file` column from the primary dataset's
Parquet files (a columnar read -- cheap even at scale, since it never touches
the rest of each row), aggregates an exact row count per source file, and
reports:
- **mismatched**: a source file whose manifest-recorded count doesn't match
  what's actually in the data (catches partial/truncated writes, not just
  entirely-missing ones).
- **missing_from_manifest**: a source file that shows up in the data but
  isn't in the manifest at all.

Per-file lines for either are capped at 20 (`... and N more`) -- a destination
with a genuine large-scale problem (or, as happened once, an old manifest
compared across a schema change) could otherwise dump hundreds of thousands of
`WARNING` lines. The summary counts at the top are never capped.

`--filter` output is deliberately excluded from this check (it only ever
holds a subset of the primary data by design, so comparing it against the
manifest wouldn't mean anything).

`--workers` (default 16, same as `consolidate`) sizes the S3 connection pool
for reading the Parquet files back -- same underlying fix as "Concurrency"
above (`wr.config.botocore_config`, since `awswrangler` hardcodes its own
internal client's pool size otherwise). This isn't optional at scale: the
first real run of this command against a large multi-file destination hit
actual `ReadTimeoutError`s from pool exhaustion before this was wired up here
too.

```bash
python cli.py verify --to ... --rebuild-manifest
```

`--rebuild-manifest` backs up the existing `manifest.json.gz` (to a
timestamped `manifest.json.gz.bak-<UTC timestamp>` sibling key) and then
replaces it outright with counts derived straight from the data. Two things
to know before using it:
- It's a full replace, not a merge -- anything in the old manifest that isn't
  corroborated by the data is gone (which is the point: the rebuilt manifest
  is only as good as what's actually durable).
- Rebuilt entries store `etag=null`, since rebuilding reads the *output*, not
  the source bucket, and has no way to know each source file's current ETag.
  An entry with a null ETag is always treated as already processed on future
  runs, regardless of the source file's actual current ETag -- so rebuilding
  trades away the (already rare) same-key-redelivered-with-different-content
  detection for files that predate the rebuild. Files processed by normal
  `consolidate` runs after a rebuild still get real ETags as usual.

`--rebuild-manifest` doesn't print the mismatched/missing report at all --
that report reflects the *old* manifest compared against the data, computed
before the rebuild replaces it. After any rebuild (and especially a schema
migration, e.g. from an old bare-key manifest to the current full-`s3://`-URL
keys) that comparison is expected to look like ~100% mismatched, since the
old entries' keys don't even have the same shape as the new ones -- that's
noise from the migration itself, not a real problem, so it's suppressed in
favor of just the summary counts, which describe the freshly-rebuilt (and
therefore self-consistent by construction) manifest.

## Auditing for duplicates and completeness

`manifest.json` dedup only catches the same source key being processed twice
*within one destination*. It can't catch the same underlying event arriving
via two genuinely different source files -- e.g. two separate Trails
configured for the same account, each delivering their own copy of the same
management events to a different S3 layout. For that, every row carries an
`orig_file` column (the full `s3://bucket/key` the record was parsed from),
so you can audit for it directly in Athena. CloudTrail's `eventid` is assigned
once per underlying API call and stays the same across trails, so a
same-`eventid`-different-`orig_file` pair is a genuine cross-source duplicate:

```sql
-- same event captured from more than one source file
SELECT eventid, array_agg(DISTINCT orig_file) AS sources, count(*) AS copies
FROM cloudtrail_logs.consolidated
WHERE year='2026' AND month='202607'
GROUP BY eventid
HAVING count(DISTINCT orig_file) > 1;

-- completeness check: every source file that contributed at least one row
SELECT orig_file, count(*) AS records
FROM cloudtrail_logs.consolidated
WHERE year='2026' AND month='202607'
GROUP BY orig_file;
```

If you do find cross-Trail duplicates, dedup at query time with
`ROW_NUMBER() OVER (PARTITION BY eventid ORDER BY orig_file) = 1`, or run a
one-off CTAS to materialize a deduplicated copy -- `orig_file` is deliberately
just data in the table, not something the tool dedupes automatically.

## Writing a filter

A filter is a module with:

```python
SUBPATH = "my_filter/"          # appended to --to's prefix for this filter's output
def matches(record: dict) -> bool: ...   # record is one raw CloudTrail record
```

See `filters/errors_and_writes.py` and `filters/s3_data_events.py` for
working examples. Pass `--filter filters.my_filter` (repeatable) to
`consolidate`.

## Athena schema

Columns mirror the shape of [AWS's own documented CloudTrail Athena
schema](https://docs.aws.amazon.com/athena/latest/ug/create-cloudtrail-table-partition-projection.html)
(scalar fields like eventName/awsRegion/errorCode as native STRING columns;
nested/variable-shape fields like userIdentity/requestParameters/
responseElements/resources as JSON-encoded STRING columns, queryable with
`json_extract_scalar(...)` the same way you'd query the raw JSON table). One
extra column, `orig_file`, isn't from CloudTrail at all -- see "Auditing for
duplicates and completeness" above. See `cloudtrail_schema.py` for the exact
column list and `athena_ddl.py` for the generated DDL.

Partitions are traditional Glue Catalog entries, **not** partition
projection -- that AWS doc uses projection for the raw-JSON table, but it
turned out to be the wrong tradeoff here. An unfiltered aggregate query
(`count(*)` with no `year`/`month`/`day` filter) has to probe every candidate
partition in the declared projection range before it can even start scanning
real data; with a range starting in 2020 and real data starting 2024-03-05,
that meant probing well over a thousand candidate day-partitions that don't
exist, which ended up dominating query time far more than the actual data
scan (confirmed directly: a query filtered to one month scanned 12.8MB in
~1 minute, while the unfiltered version was still running 25+ minutes later
having scanned only 34.8MB). A Catalog-registered table only ever touches
partitions that actually exist, at the cost of needing `MSCK REPAIR TABLE`
to register new ones -- which `consolidate` now runs automatically after
any run that writes new data (see `_repair_partitions()` in `convert.py`).
If that repair fails (e.g. the table doesn't exist yet because `create-table`
hasn't been run against this destination), it logs a warning rather than
failing the run -- the data write already succeeded, which matters more than
the repair.

The `MSCK REPAIR TABLE` query's results are written to
`s3://<to-bucket>/<to-prefix>_athena_results/` (a sibling of `_manifest/`,
same "not a data file" convention) rather than left unset -- an unset
`s3_output` makes `awswrangler` fall back to the unpredictable,
account/region-global default results bucket
(`aws-athena-query-results-{account}-{region}`) and warn about it on every
single call.

Still worth filtering on `year`/`month`/`day` in your own queries when you
can, even loosely -- it's what lets Athena prune to only the partitions that
matter instead of scanning the whole table.

## Deploying as a Glue Python Shell job

`aws/` has Terraform for the Glue job (Python Shell, not Spark -- cheap,
no cluster cold start), its IAM role, and the Athena database/table
(`athena.tf`, the same traditional partition scheme as `create-table` above).
See `aws/README.md` for deploy steps.
