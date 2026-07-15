"""filters/: the plugin contract and the two shipped example filters."""
import pytest

from conftest import cloudtrail_record
from filters import load_filter
from filters import errors_and_writes, s3_data_events


def test_load_filter_returns_module_with_contract():
    mod = load_filter("filters.errors_and_writes")
    assert hasattr(mod, "SUBPATH")
    assert hasattr(mod, "matches")


def test_load_filter_rejects_module_missing_contract():
    with pytest.raises(ValueError):
        load_filter("cloudtrail_schema")  # a real module, but not a filter


def test_errors_and_writes_matches_error_code():
    assert errors_and_writes.matches(cloudtrail_record(errorCode="AccessDenied")) is True


def test_errors_and_writes_matches_non_readonly():
    assert errors_and_writes.matches(cloudtrail_record(readOnly=False, errorCode=None)) is True


def test_errors_and_writes_excludes_successful_readonly():
    assert errors_and_writes.matches(cloudtrail_record(readOnly=True, errorCode=None)) is False


def test_s3_data_events_matches_s3_data_category():
    record = cloudtrail_record(eventSource="s3.amazonaws.com", eventName="GetObject", eventCategory="Data")
    assert s3_data_events.matches(record) is True


def test_s3_data_events_excludes_non_s3_source():
    record = cloudtrail_record(eventSource="ec2.amazonaws.com", eventCategory="Data")
    assert s3_data_events.matches(record) is False


def test_s3_data_events_excludes_management_events():
    record = cloudtrail_record(eventSource="s3.amazonaws.com", eventCategory="Management")
    assert s3_data_events.matches(record) is False
