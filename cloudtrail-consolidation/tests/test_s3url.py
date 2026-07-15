"""s3url.py: s3:// URL parsing and the single-wildcard region expansion."""
import boto3
import pytest
from botocore.stub import Stubber

import s3url


def test_parse_s3_url():
    assert s3url.parse_s3_url("s3://bucket/some/prefix/") == ("bucket", "some/prefix/")
    assert s3url.parse_s3_url("s3://bucket/") == ("bucket", "")


def test_parse_s3_url_rejects_non_s3_scheme():
    with pytest.raises(ValueError):
        s3url.parse_s3_url("https://bucket/prefix/")


def test_to_s3_url_round_trips_with_parse():
    bucket, prefix = "my-bucket", "a/b/c/"
    assert s3url.parse_s3_url(s3url.to_s3_url(bucket, prefix)) == (bucket, prefix)


def test_split_wildcard():
    before, after = s3url.split_wildcard("AWSLogs/123/CloudTrail/*/2026/07/01/")
    assert before == "AWSLogs/123/CloudTrail/"
    assert after == "2026/07/01/"


def test_split_wildcard_rejects_more_than_one_wildcard():
    with pytest.raises(NotImplementedError):
        s3url.split_wildcard("a/*/b/*/c/")


def test_split_wildcard_rejects_no_wildcard():
    with pytest.raises(ValueError):
        s3url.split_wildcard("a/b/c/")


def test_has_wildcard():
    assert s3url.has_wildcard("a/*/b/") is True
    assert s3url.has_wildcard("a/b/") is False


def test_expand_wildcard_yields_one_prefix_per_region():
    s3 = boto3.client("s3", region_name="us-east-1", aws_access_key_id="x", aws_secret_access_key="y")
    stub = Stubber(s3)
    stub.add_response(
        "list_objects_v2",
        {
            "CommonPrefixes": [
                {"Prefix": "AWSLogs/123/CloudTrail/us-east-1/"},
                {"Prefix": "AWSLogs/123/CloudTrail/us-west-2/"},
            ],
            "IsTruncated": False,
        },
        {"Bucket": "b", "Prefix": "AWSLogs/123/CloudTrail/", "Delimiter": "/"},
    )
    stub.activate()

    prefixes = list(s3url.expand_wildcard(s3, "b", "AWSLogs/123/CloudTrail/*/2026/07/01/"))
    assert prefixes == [
        "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
        "AWSLogs/123/CloudTrail/us-west-2/2026/07/01/",
    ]


def test_expand_wildcard_paginates():
    s3 = boto3.client("s3", region_name="us-east-1", aws_access_key_id="x", aws_secret_access_key="y")
    stub = Stubber(s3)
    stub.add_response(
        "list_objects_v2",
        {"CommonPrefixes": [{"Prefix": "AWSLogs/123/CloudTrail/us-east-1/"}],
         "IsTruncated": True, "NextContinuationToken": "tok"},
        {"Bucket": "b", "Prefix": "AWSLogs/123/CloudTrail/", "Delimiter": "/"},
    )
    stub.add_response(
        "list_objects_v2",
        {"CommonPrefixes": [{"Prefix": "AWSLogs/123/CloudTrail/us-west-2/"}], "IsTruncated": False},
        {"Bucket": "b", "Prefix": "AWSLogs/123/CloudTrail/", "Delimiter": "/", "ContinuationToken": "tok"},
    )
    stub.activate()

    prefixes = list(s3url.expand_wildcard(s3, "b", "AWSLogs/123/CloudTrail/*/2026/"))
    assert prefixes == [
        "AWSLogs/123/CloudTrail/us-east-1/2026/",
        "AWSLogs/123/CloudTrail/us-west-2/2026/",
    ]


def test_resolve_prefixes_without_wildcard_returns_unchanged():
    s3 = boto3.client("s3", region_name="us-east-1", aws_access_key_id="x", aws_secret_access_key="y")
    assert s3url.resolve_prefixes(s3, "b", "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/") == [
        "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/"
    ]
