"""Tunables shared between cli.py and convert.py, kept dependency-free (no
awswrangler/pandas) so cli.py can reference them (e.g. for argparse choices/
defaults) without paying convert.py's heavier import cost for subcommands
that don't need it (create-table)."""

# Flush a batch of accumulated records to Parquet after roughly this many rows,
# to bound memory -- CloudTrail records are small but files/prefixes can be huge.
DEFAULT_BATCH_ROWS = 200_000

# How often (seconds) to log a progress line when show_progress is on -- not
# per-file, since a run over thousands of small files would flood stderr.
DEFAULT_PROGRESS_INTERVAL = 5.0

# Concurrent S3 GetObject + gunzip + json.loads calls. This is I/O-bound (one
# file's fetch does nothing to block another's), so threads -- not processes
# or async -- are the right tool; the GIL is released during both the network
# wait and zlib's C-level decompression.
DEFAULT_WORKERS = 16

# --chunk-by only reorders the (already-listed, already-deduped) file list
# before processing -- it does not split work across processes or change when
# manifest.json is saved (that stays purely row-count driven via batch_rows).
# It exists so you can experiment with whether e.g. finishing one region (or
# one day) at a time changes throughput, without any change in correctness.
CHUNK_BY_CHOICES = ("none", "date", "region", "region-date")
