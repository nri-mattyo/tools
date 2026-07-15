"""stats.py: running counters and their derived throughput rates."""
import time

from stats import Stats


def test_counters_accumulate():
    s = Stats()
    s.skip(3)
    s.record_file(1000, 50)
    s.record_file(2000, 75)
    assert s.files_processed == 2
    assert s.files_skipped == 3
    assert s.bytes_processed == 3000
    assert s.lines_processed == 125


def test_rates_are_positive_after_some_elapsed_time():
    s = Stats()
    s.record_file(1000, 50)
    time.sleep(0.01)
    assert s.bytes_per_sec() > 0
    assert s.lines_per_sec() > 0


def test_rates_are_zero_with_no_recorded_work():
    s = Stats()
    assert s.bytes_per_sec() == 0
    assert s.lines_per_sec() == 0


def test_progress_and_summary_lines_include_all_fields():
    s = Stats()
    s.skip(1)
    s.record_file(500, 10)
    progress = s.progress_line()
    summary = s.summary_line()
    for field in ("files_processed", "files_skipped", "bytes_processed", "lines_processed"):
        assert field in progress
        assert field in summary
    assert "elapsed_sec" in summary and "elapsed_sec" not in progress
