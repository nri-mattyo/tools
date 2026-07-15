"""cli.py: cmd_verify's reporting -- capping long mismatch/missing lists, and
suppressing the (expected-to-be-100%-noisy) pre-rebuild diff when
--rebuild-manifest is used. Added after a real run against 242K files dumped
a 512KB/485,000-line log purely from comparing an old-schema manifest against
freshly-migrated data."""
import argparse
import logging

import pytest

import cli
import verify as verify_mod


def _args(**overrides):
    base = dict(to="s3://bucket/prefix/", to_bucket=None, to_prefix=None, to_profile=None,
                profile=None, rebuild_manifest=False, workers=16)
    base.update(overrides)
    return argparse.Namespace(**base)


@pytest.fixture
def fake_report(monkeypatch):
    """Swap out verify.verify() with one returning a canned report, so
    cmd_verify's logging logic can be tested without touching S3/awswrangler."""
    calls = {}

    def fake_verify(session, bucket, prefix, rebuild=False, workers=16):
        calls["rebuild"] = rebuild
        return calls["report"]

    monkeypatch.setattr(verify_mod, "verify", fake_verify)
    return calls


def test_clean_report_logs_verified_ok(fake_report, caplog):
    fake_report["report"] = {"manifest_entries": 5, "distinct_files_in_data": 5,
                              "total_rows_in_data": 50, "mismatched": [], "missing_from_manifest": []}
    with caplog.at_level(logging.INFO):
        cli.cmd_verify(_args())
    assert "verified OK" in caplog.text


def test_long_mismatch_list_is_capped_with_a_summary(fake_report, caplog):
    mismatched = [(f"s3://b/file{i}.json.gz", 10, 5) for i in range(100)]
    fake_report["report"] = {"manifest_entries": 100, "distinct_files_in_data": 100,
                              "total_rows_in_data": 500, "mismatched": mismatched, "missing_from_manifest": []}
    with caplog.at_level(logging.WARNING):
        cli.cmd_verify(_args())

    file_lines = [r for r in caplog.records if "file" in r.message and ".json.gz" in r.message]
    assert len(file_lines) == cli.MAX_REPORTED_ISSUES
    assert any("... and 80 more" in r.message for r in caplog.records)


def test_long_missing_list_is_capped_with_a_summary(fake_report, caplog):
    missing = [f"s3://b/file{i}.json.gz" for i in range(50)]
    fake_report["report"] = {"manifest_entries": 0, "distinct_files_in_data": 50,
                              "total_rows_in_data": 500, "mismatched": [], "missing_from_manifest": missing}
    with caplog.at_level(logging.WARNING):
        cli.cmd_verify(_args())

    file_lines = [r for r in caplog.records if "file" in r.message and ".json.gz" in r.message]
    assert len(file_lines) == cli.MAX_REPORTED_ISSUES
    assert any(f"... and {50 - cli.MAX_REPORTED_ISSUES} more" in r.message for r in caplog.records)


def test_short_list_is_not_truncated_and_has_no_summary_line(fake_report, caplog):
    mismatched = [("s3://b/a.json.gz", 10, 5)]
    fake_report["report"] = {"manifest_entries": 1, "distinct_files_in_data": 1,
                              "total_rows_in_data": 5, "mismatched": mismatched, "missing_from_manifest": []}
    with caplog.at_level(logging.WARNING):
        cli.cmd_verify(_args())
    assert not any("more" in r.message for r in caplog.records)


def test_rebuild_suppresses_the_stale_prerebuild_diff_noise(fake_report, caplog):
    """After --rebuild-manifest, the report dict still reflects the OLD
    manifest vs. the data (computed before the rebuild) -- comparing an old
    bare-key manifest against full-URL-keyed data looks like 100% mismatch,
    which is expected noise from the migration itself, not a real problem.
    cmd_verify must not print that when rebuild_manifest=True."""
    mismatched = [(f"s3://b/file{i}.json.gz", 10, 0) for i in range(242419)]
    fake_report["report"] = {"manifest_entries": 242419, "distinct_files_in_data": 242419,
                              "total_rows_in_data": 5000000, "mismatched": mismatched,
                              "missing_from_manifest": [m[0] for m in mismatched]}
    with caplog.at_level(logging.INFO):
        cli.cmd_verify(_args(rebuild_manifest=True))

    assert fake_report["rebuild"] is True
    assert not any("mismatch" in r.message for r in caplog.records)
    assert not any("missing from the manifest" in r.message for r in caplog.records)
    assert any("rebuilt from the data" in r.message for r in caplog.records)
