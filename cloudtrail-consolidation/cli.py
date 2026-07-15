#!/usr/bin/env python3
"""cloudtrail-consolidation: merge raw per-region CloudTrail JSON.gz files into
partitioned Parquet, tracking what's already been merged in a manifest, and
optionally registering/creating the Athena table over the result.

    python cli.py consolidate --profile my-profile \\
        --from s3://bucket/AWSLogs/123/CloudTrail/*/2026/07/01/ \\
        --to   s3://dest-bucket/cloudtrail/ \\
        --filter filters.errors_and_writes --filter filters.s3_data_events

    python cli.py create-table --to s3://dest-bucket/cloudtrail/ --execute

Same --from/--to accept either a full s3:// URL or --from-bucket/--from-prefix
(and --to-bucket/--to-prefix) given separately.

Reading and writing can use different AWS accounts/credentials (e.g. reading a
source account's CloudTrail bucket, writing to a central analytics account):
--from-profile/AWS_FROM_PROFILE and --to-profile/AWS_TO_PROFILE each override
--profile/AWS_PROFILE for just that side; --profile/AWS_PROFILE alone is used
for both sides when the more specific ones aren't given.
"""
import argparse
import logging
import os
import sys

import boto3

from athena_ddl import DEFAULT_DATABASE, build_ddl, default_table_name
from defaults import CHUNK_BY_CHOICES, DEFAULT_BATCH_ROWS, DEFAULT_WORKERS
from filters import load_filter
from s3url import parse_s3_url, to_s3_url

log = logging.getLogger("cli")


def _resolve_location(args, side):
    """side: "from" or "to". Returns (bucket, prefix) from either --from/--to
    or --{side}-bucket/--{side}-prefix."""
    url = getattr(args, side)
    bucket = getattr(args, f"{side}_bucket")
    prefix = getattr(args, f"{side}_prefix")
    if url:
        return parse_s3_url(url)
    if not bucket:
        sys.exit(f"must pass --{side} s3://... or --{side}-bucket/--{side}-prefix")
    return bucket, prefix or ""


def _add_location_args(parser, side, help_noun):
    parser.add_argument(f"--{side}", help=f"s3://bucket/prefix for the {help_noun} (wildcard '/*/' allowed on --from)")
    parser.add_argument(f"--{side}-bucket", help=f"{help_noun} bucket, if not using --{side}")
    parser.add_argument(f"--{side}-prefix", help=f"{help_noun} prefix, if not using --{side}")


def _resolve_profile(args, side):
    """side: "from" or "to". --{side}-profile / AWS_{SIDE}_PROFILE win if given,
    else fall back to --profile (which itself falls back to AWS_PROFILE / the
    default credential chain via boto3.Session(profile_name=None))."""
    return (getattr(args, f"{side}_profile")
            or os.environ.get(f"AWS_{side.upper()}_PROFILE")
            or args.profile)


def _session_for(args, side):
    profile = _resolve_profile(args, side)
    return boto3.Session(profile_name=profile) if profile else boto3.Session()


def cmd_consolidate(args):
    import convert  # deferred: pulls in awswrangler/pandas, not needed for other subcommands

    from_session = _session_for(args, "from")
    to_session = _session_for(args, "to")
    from_bucket, from_prefix = _resolve_location(args, "from")
    to_bucket, to_prefix = _resolve_location(args, "to")
    filters = [load_filter(spec) for spec in (args.filter or [])]

    n = convert.consolidate(from_session, from_bucket, from_prefix, to_session, to_bucket, to_prefix,
                             filters=filters, dry_run=args.dry_run, show_progress=args.progress,
                             workers=args.workers, chunk_by=args.chunk_by, batch_rows=args.batch_size,
                             database=args.database, table=args.table)
    if args.dry_run:
        log.info("dry run: %d new file(s) would be processed", n)
    else:
        log.info("done: %d new file(s) processed -> %s", n, to_s3_url(to_bucket, to_prefix))


MAX_REPORTED_ISSUES = 20  # cap per-file WARNING lines; a destination with real problems could
                          # otherwise dump hundreds of thousands of lines (seen in practice)


def _log_capped(header, items, formatter):
    log.warning(header, len(items))
    for item in items[:MAX_REPORTED_ISSUES]:
        log.warning("  %s", formatter(item))
    if len(items) > MAX_REPORTED_ISSUES:
        log.warning("  ... and %d more", len(items) - MAX_REPORTED_ISSUES)


def cmd_verify(args):
    import verify as verify_mod  # deferred: pulls in awswrangler, not needed for other subcommands

    to_bucket, to_prefix = _resolve_location(args, "to")
    session = _session_for(args, "to")
    report = verify_mod.verify(session, to_bucket, to_prefix, rebuild=args.rebuild_manifest, workers=args.workers)

    log.info("manifest entries: %d | distinct files found in data: %d | total rows in data: %d",
              report["manifest_entries"], report["distinct_files_in_data"], report["total_rows_in_data"])

    if args.rebuild_manifest:
        # report reflects the PRE-rebuild manifest vs. the data -- after a schema change (or any
        # rebuild) that comparison is expected to look like "everything mismatched", since the old
        # entries' keys don't even have the same shape as the new orig_file-derived ones. That's
        # not a real problem, just noise from the migration itself, so don't print it: the summary
        # line above already describes the freshly-rebuilt (and therefore self-consistent by
        # construction) manifest.
        log.info("manifest rebuilt from the data; the counts above describe the new manifest")
        return

    if report["mismatched"]:
        _log_capped("%d file(s) have a row-count mismatch between manifest and data:", report["mismatched"],
                     lambda m: f"{m[0]}: manifest says {m[1]}, data has {m[2]}")
    if report["missing_from_manifest"]:
        _log_capped("%d file(s) found in data but missing from the manifest:", report["missing_from_manifest"],
                     lambda orig_file: orig_file)
    if not report["mismatched"] and not report["missing_from_manifest"]:
        log.info("verified OK: manifest matches the data exactly")


def cmd_create_table(args):
    to_bucket, to_prefix = _resolve_location(args, "to")
    database = args.database or DEFAULT_DATABASE
    table = args.table or default_table_name(to_prefix)
    ddl = build_ddl(database, table, to_bucket, to_prefix)
    print(ddl)
    if args.execute:
        import awswrangler as wr
        session = _session_for(args, "to")  # create-table only ever touches the destination
        wr.athena.start_query_execution(sql=ddl, database=database, boto3_session=session,
                                         wait=True)
        log.info("created/updated %s.%s", database, table)


def main():
    # --profile/-v are defined on a shared parent parser so they can appear
    # either before or after the subcommand (argparse doesn't let a subparser
    # see its parent's own optionals otherwise).
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--profile", help="AWS profile (else AWS_PROFILE / default credential chain)")
    common.add_argument("-v", "--verbose", action="store_true")

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                      parents=[common])
    sub = parser.add_subparsers(dest="command", required=True)

    p_consolidate = sub.add_parser("consolidate", parents=[common],
                                    help="merge new raw CloudTrail files into partitioned Parquet")
    _add_location_args(p_consolidate, "from", "source (raw CloudTrail logs)")
    _add_location_args(p_consolidate, "to", "destination (consolidated Parquet)")
    p_consolidate.add_argument("--from-profile",
                                help="AWS profile for reading --from (else AWS_FROM_PROFILE, else --profile)")
    p_consolidate.add_argument("--to-profile",
                                help="AWS profile for writing --to (else AWS_TO_PROFILE, else --profile)")
    p_consolidate.add_argument("--filter", action="append",
                                help="dotted path to a filter module (e.g. filters.errors_and_writes); repeatable")
    p_consolidate.add_argument("--dry-run", action="store_true",
                                help="list the new files that would be processed and exit")
    p_consolidate.add_argument("--progress", action="store_true",
                                help="log running stats (files/bytes/records, throughput) to stderr during the run; "
                                     "a final summary is always logged regardless of this flag")
    p_consolidate.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                                help=f"concurrent S3 fetch/parse threads (default: {DEFAULT_WORKERS})")
    p_consolidate.add_argument("--chunk-by", choices=CHUNK_BY_CHOICES, default="none",
                                help="reorder files by this key before processing, for experimenting with "
                                     "throughput (default: none -- process in listing order); doesn't change "
                                     "correctness or when manifest.json is saved")
    p_consolidate.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_ROWS,
                                help=f"rows accumulated in memory before a Parquet flush + manifest save "
                                     f"(default: {DEFAULT_BATCH_ROWS})")
    p_consolidate.add_argument("--database", help=f"Athena/Glue database to repair partitions in after a "
                                                   f"successful run (default: {DEFAULT_DATABASE})")
    p_consolidate.add_argument("--table", help="Athena table to repair partitions in (default: derived from "
                                                "--to's last path segment, same as create-table)")
    p_consolidate.set_defaults(func=cmd_consolidate)

    p_verify = sub.add_parser("verify", parents=[common],
                               help="check manifest.json against what's actually durable in the Parquet data")
    _add_location_args(p_verify, "to", "consolidated Parquet destination")
    p_verify.add_argument("--to-profile", help="AWS profile for --to (else AWS_TO_PROFILE, else --profile)")
    p_verify.add_argument("--rebuild-manifest", action="store_true",
                           help="replace manifest.json with counts derived directly from the data (backing up "
                                "the existing manifest first); also migrates old bare-key manifests to the "
                                "s3://bucket/key schema, but loses each file's ETag -- rebuilt entries store "
                                "etag=null and are always treated as already processed on future runs")
    p_verify.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                           help=f"sizes the S3 connection pool for reading back Parquet files "
                                f"(default: {DEFAULT_WORKERS})")
    p_verify.set_defaults(func=cmd_verify)

    p_table = sub.add_parser("create-table", parents=[common],
                              help="print (and optionally run) the Athena CREATE TABLE DDL")
    _add_location_args(p_table, "to", "consolidated Parquet destination")
    p_table.add_argument("--to-profile",
                          help="AWS profile to run the DDL with (else AWS_TO_PROFILE, else --profile)")
    p_table.add_argument("--database", help=f"Athena/Glue database (default: {DEFAULT_DATABASE})")
    p_table.add_argument("--table", help="table name (default: derived from --to's last path segment)")
    p_table.add_argument("--execute", action="store_true", help="actually run the DDL via Athena, not just print it")
    p_table.set_defaults(func=cmd_create_table)

    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                         format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # Without this, Ctrl-C mid-run dumps a multi-frame traceback from
        # wherever the interrupt happened to land (often deep inside a
        # ThreadPoolExecutor future's .result() wait) -- alarming, and not
        # actionable. manifest.json already reflects every completed flush
        # (see "How dedup works" in the README), so exiting here loses at
        # most the in-memory rows accumulated since the last flush, not
        # anything already written; re-running is safe.
        print("\ninterrupted -- manifest.json reflects the last completed flush; re-run to pick up where it left off",
              file=sys.stderr)
        sys.exit(130)  # 128 + SIGINT(2), the conventional exit code for Ctrl-C
