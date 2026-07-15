"""Builds the Athena CREATE EXTERNAL TABLE DDL for a consolidated destination,
using a traditional Glue Catalog-registered partition scheme -- partitions
are real Glue Catalog entries, kept current via MSCK REPAIR TABLE (see
repair_table_sql()), not computed on the fly.

This replaced an earlier partition-projection design (no ADD PARTITION ever
needed, partitions computed from a declared range at query time). Projection
turned out to be the wrong tradeoff here: an unfiltered aggregate query had
to probe thousands of candidate day-partitions (the declared range went back
to 2020; real data starts 2024-03-05) before it could even start scanning
real data, dominating query time. A Catalog-registered table only ever
touches partitions that actually exist.
"""
from cloudtrail_schema import DDL_COLUMNS

DEFAULT_DATABASE = "cloudtrail_logs"


def default_table_name(prefix):
    """Last non-empty path segment of a prefix, e.g. "cloudtrail/prod/" -> "prod"."""
    segments = [s for s in prefix.split("/") if s]
    return segments[-1] if segments else "cloudtrail_logs"


def build_ddl(database, table, bucket, prefix):
    prefix = prefix if prefix.endswith("/") else prefix + "/"
    location = f"s3://{bucket}/{prefix}"
    columns_sql = ",\n  ".join(f"{col} STRING" for col in DDL_COLUMNS)
    return f"""CREATE EXTERNAL TABLE IF NOT EXISTS {database}.{table} (
  {columns_sql}
)
PARTITIONED BY (year STRING, month STRING, day STRING)
STORED AS PARQUET
LOCATION '{location}';"""


def repair_table_sql(database, table):
    """MSCK REPAIR TABLE scans the table's LOCATION for year=/month=/day=
    directories and registers any that aren't already in the Glue Catalog --
    the traditional-partitioning equivalent of what projection did
    automatically. Needs re-running whenever new partitions land (see
    convert.py's consolidate(), which does this after every run that wrote
    new data)."""
    return f"MSCK REPAIR TABLE {database}.{table};"
