"""Running counters for a consolidate() run: files processed/skipped, bytes
and records read, and the resulting throughput rates. Kept separate from
convert.py so it's trivially unit-testable without touching S3/awswrangler.
"""
import time


class Stats:
    def __init__(self):
        self.files_processed = 0
        self.files_skipped = 0
        self.bytes_processed = 0
        self.lines_processed = 0
        self._start = time.monotonic()

    def elapsed(self):
        return max(time.monotonic() - self._start, 1e-9)  # avoid /0 on a near-instant run

    def bytes_per_sec(self):
        return self.bytes_processed / self.elapsed()

    def lines_per_sec(self):
        return self.lines_processed / self.elapsed()

    def skip(self, n=1):
        self.files_skipped += n

    def record_file(self, size_bytes, line_count):
        self.files_processed += 1
        self.bytes_processed += size_bytes or 0
        self.lines_processed += line_count

    def progress_line(self):
        return (f"progress: files_processed={self.files_processed} files_skipped={self.files_skipped} "
                f"bytes_processed={self.bytes_processed} lines_processed={self.lines_processed} "
                f"bytes_per_sec={self.bytes_per_sec():.0f} lines_per_sec={self.lines_per_sec():.0f}")

    def summary_line(self):
        return (f"summary: files_processed={self.files_processed} files_skipped={self.files_skipped} "
                f"bytes_processed={self.bytes_processed} lines_processed={self.lines_processed} "
                f"elapsed_sec={self.elapsed():.1f} avg_bytes_per_sec={self.bytes_per_sec():.0f} "
                f"avg_lines_per_sec={self.lines_per_sec():.0f}")
