# CloudTrail Duplication Cleanup Plan (Account 381492092437)

**Status: PLAN ONLY — nothing in this document has been executed.** Every write/delete
API call below requires explicit, separate approval before it is run, per standing
instruction. This file exists so that approval can happen action-by-action instead of
all at once.

## 1. Background / what we found

Account `381492092437` has two independently-configured multi-region CloudTrail trails,
both feeding the same consolidated Athena table (`cloudtrail_logs.consolidated`):

| Trail | Bucket | Scope | Since |
|---|---|---|---|
| `api-events` | `aws-cloudtrail-logs-381492092437-74dbd159` | management events only | 2024-04-02 |
| `main-cloudtrail` | `nri-cloudtrail-logs-381492092437` | management + S3 + Lambda data events | 2025-07-28 |

Both trails deliver overlapping management-event data independently — same `eventID`s,
different raw files, different buckets. Analysis of 2026 data found **77.5% of distinct
events duplicated** across the two sources. Neither bucket has any S3-notification-based
downstream consumer (both checked, both empty), so there is no other system depending on
either raw copy directly.

Separately, `nri-cloudtrail-logs-381492092437` (the `main-cloudtrail` bucket) has a
bucket-wide S3 Lifecycle rule: `Expiration.Days = 180`, `Filter.Prefix = ""` (applies to
every object in the bucket, including the consolidated tool's own Parquet output, which
shares this bucket). We confirmed this rule is **actively deleting raw `main-cloudtrail`
source data on schedule** — delete markers dated `2026-01-28/29` on objects originally
delivered `2025-08-01`, consistent with a 180-day expiration. This is why
`main-cloudtrail`'s earliest surviving raw data is `2026-01-03`, not its 2025-07-28
creation date — everything before `2026-01-03` already expired before this analysis, and
before the consolidation tool ever had a chance to back it up.

## 2. Recommendation: eliminate the lifecycle rule entirely

Per your direction, `main-cloudtrail` (covering management + S3 + Lambda data events) is
now this account's source of truth, and **all data should be retained until further
notice** — not just the consolidated output. Rather than scoping the existing rule to
exclude the consolidated-output prefix, **delete the lifecycle rule outright** so nothing
in `nri-cloudtrail-logs-381492092437` expires going forward.

**Recommended API call (write — needs approval):**
```bash
aws s3api delete-bucket-lifecycle \
  --bucket nri-cloudtrail-logs-381492092437 \
  --profile nri-develop
```
This removes the *entire* lifecycle configuration on the bucket (confirmed via
`get-bucket-lifecycle-configuration` that this rule is currently the only one present, so
there is nothing else to preserve). Read-only verification after running it:
```bash
aws s3api get-bucket-lifecycle-configuration \
  --bucket nri-cloudtrail-logs-381492092437 --profile nri-develop
# expect: NoSuchLifecycleConfiguration error
```

You asked for this to happen "by Monday" — that's **2026-07-06**.

## 3. Overlap window: when is `api-events` data safe to remove from the consolidated table

The naive assumption — "safe once `main-cloudtrail` existed," i.e. 2025-07-28 onward — is
**wrong** and would cause permanent data loss. Because the lifecycle rule already expired
`main-cloudtrail`'s raw data from 2025-07-28 through 2026-01-02 before that span was ever
consolidated, `api-events` is currently the **sole surviving copy** of that period's
management events. Removing `api-events` rows for that span would destroy the only copy.

We confirmed this with a day-by-day Athena breakdown of the consolidated table (550 days,
zero gaps): `main_cloudtrail_records` is exactly 0 for every day through `2026-01-02`, and
non-zero starting exactly `2026-01-03`.

**Confirmed safe-to-remove overlap window: `2026-01-03` through `2026-07-04`.**

- Before `2026-01-03`: `api-events` is the only surviving copy — **must be retained
  indefinitely**, not just until Monday.
- `2026-01-03` onward: both trails have independently delivered the same events, so the
  `api-events` copy is redundant with `main-cloudtrail`'s.
- `2026-07-04` is used as the window's end (rather than "today") to stay a day behind the
  most recent complete day of confirmed dual-delivery, avoiding any partial/in-flight
  day at the boundary.

This window is contingent on the lifecycle rule being eliminated per §2 before it's acted
on — otherwise the same expiration risk just recurs for the current window on a rolling
180-day basis.

**Quantified impact of the overlap window** (Athena, read-only `SELECT`):
- `api_events_rows_in_overlap` = **42,901,396** consolidated rows sourced from `api-events`
  raw files, dated `2026-01-03`–`2026-07-04`
- `api_events_distinct_files_in_overlap` = **298,522** distinct `api-events` raw source
  files referenced by those rows

## 4. Recommendation: remove the duplicate consolidated rows

The consolidated table is Parquet-backed and partitioned by `year`/`month`/`day` — Athena
doesn't support row-level `DELETE` against it. The standard approach is a
CTAS-and-swap per affected partition: rebuild each `day=` partition's data with the
`api-events`-sourced rows filtered out, then replace the partition's files.

**Recommended approach (write — needs approval, and should be reviewed partition-by-partition
rather than run as one blind operation):**

For each `day` partition in `[20260103, 20260704]`:

1. CTAS into a staging location, excluding `api-events` rows:
   ```sql
   CREATE TABLE cloudtrail_logs.consolidated_staging_<day>
   WITH (format = 'PARQUET', external_location = 's3://<to-bucket>/cloudtrail/_staging/<day>/')
   AS SELECT * FROM cloudtrail_logs.consolidated
   WHERE year = '2026' AND month = '<yyyymm>' AND day = '<day>'
     AND orig_file NOT LIKE '%aws-cloudtrail-logs-381492092437-74dbd159%';
   ```
2. Verify row count: `main_cloudtrail`-sourced rows for that day should be unchanged;
   `api-events`-sourced rows should be gone.
3. Only after verification, replace the live partition's S3 objects with the staged
   output (`aws s3 sync --delete` from staging to the live partition prefix, or an
   `ALTER TABLE ... SET LOCATION` swap) and drop the staging table.

This is deliberately left as a per-partition, reviewable procedure rather than a single
irreversible bulk rewrite — 181 partitions, ~42.9M rows is large enough that a mistake in
the exclusion predicate would be costly. Recommend running it in a handful of batches with
a spot-check (row counts, a few sample `eventID`s cross-referenced against
`main-cloudtrail`) between batches, not asking for one blanket approval covering all 181
partitions.

## 5. Recommendation: delete the redundant raw S3 objects

**Object list generated (read-only `list-objects-v2`, all 17 regions,
`AWSLogs/381492092437/CloudTrail/{region}/{2026/01..2026/07}/`, filtered to
`2026-01-03`–`2026-07-04`):**

[`api_events_overlap_objects_20260103_20260704.csv`](./api_events_overlap_objects_20260103_20260704.csv)

- **299,807 objects**, **~7.33 GB** total
- Columns: `key, size, last_modified, region, day`
- Note: this is 1,285 more than the Athena `orig_file` distinct-file count (298,522).
  Expected and not a discrepancy to chase down before cleanup: Athena's count is distinct
  *source files that produced at least one row currently in the consolidated table*,
  while the S3 listing is *every object physically delivered in that date range* —
  includes delivery-manifest/digest files and any zero-record files that never produced a
  consolidated row. Recommend re-deriving the exact delete-candidate list directly from
  this CSV's `key` column at execution time (straightforward `aws s3 rm` batch), not from
  the Athena file list, since the CSV reflects the actual bucket contents.

**Recommended API calls (write — needs approval, and should run only after §4's rewrite
is verified complete for the corresponding partitions — do not delete the raw objects
before their consolidated replacement is confirmed correct):**

```bash
# Batch delete via the generated CSV, in chunks of <=1000 keys (S3 delete-objects limit):
python3 - <<'PY'
import csv, boto3
s3 = boto3.client("s3")
BUCKET = "aws-cloudtrail-logs-381492092437-74dbd159"
with open("api_events_overlap_objects_20260103_20260704.csv") as f:
    keys = [row["key"] for row in csv.DictReader(f)]
for i in range(0, len(keys), 1000):
    batch = keys[i:i+1000]
    s3.delete_objects(Bucket=BUCKET, Delete={"Objects": [{"Key": k} for k in batch]})
PY
```

Given versioning is enabled on this bucket, this creates delete markers rather than
purging data immediately — recoverable via `list-object-versions` + a targeted restore if
a mistake is found, but not indefinitely, so don't treat that as a safety net for
skipping verification in §4.

## 6. Recommendation: retire the `api-events` trail

Once the overlap-window cleanup (§4, §5) is complete and `main-cloudtrail` is confirmed as
sole source of truth going forward, `api-events` itself can be stopped/deleted — it's now
fully redundant with `main-cloudtrail`'s management-event coverage.

**Recommended API calls (write — needs approval, and should be the last step, after
everything above is verified):**
```bash
aws cloudtrail stop-logging --name api-events --profile nri-develop
# after a confirmation period with no issues:
aws cloudtrail delete-trail --name api-events --profile nri-develop
```

## 7. Suggested order of operations

1. **§2** — delete the lifecycle rule on `nri-cloudtrail-logs-381492092437` (by 2026-07-06)
2. Let a few days pass with the rule gone, confirm no further expiration-driven data loss
3. **§4** — rewrite consolidated partitions for `20260103`–`20260704`, batch by batch, with
   verification between batches
4. **§5** — delete the now-redundant raw `api-events` objects for the same window, using the
   generated CSV, only after each corresponding partition's rewrite is verified
5. **§6** — retire the `api-events` trail once (1)–(4) are complete and stable

Every step above still requires its own explicit go-ahead when you're ready to act on it —
this document is the plan, not the execution.
