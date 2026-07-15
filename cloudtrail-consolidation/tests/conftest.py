"""Shared pytest fixtures: a mocked AWS environment (moto) with a fresh source
and destination bucket per test, plus small helpers for building fake
CloudTrail delivery files without repeating the same boilerplate everywhere.
"""
import gzip
import json
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

# Tests import the tool's modules directly (cli.py, convert.py, ...) by path,
# same as they're run day to day -- no packaging/installation involved.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


@pytest.fixture(autouse=True)
def aws_credentials(monkeypatch):
    """Fake credentials so boto3 never accidentally reaches real AWS if
    mocking is somehow bypassed -- moto also needs *something* set."""
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")


@pytest.fixture
def mocked_aws(aws_credentials):
    with mock_aws():
        yield


@pytest.fixture
def session(mocked_aws):
    return boto3.Session(region_name="us-east-1")


@pytest.fixture
def buckets(session):
    """A fresh 'srcbucket' (raw CloudTrail logs) and 'dstbucket' (consolidated
    output) per test. Returns (session, s3_client) -- most tests use one
    session for both sides, matching --profile with no --from-profile/
    --to-profile override."""
    s3 = session.client("s3")
    s3.create_bucket(Bucket="srcbucket")
    s3.create_bucket(Bucket="dstbucket")
    return session, s3


def cloudtrail_record(**overrides):
    """A minimal-but-realistic CloudTrail record; override any field."""
    record = {
        "eventVersion": "1.08",
        "eventTime": "2026-07-01T10:00:00Z",
        "eventSource": "ec2.amazonaws.com",
        "eventName": "DescribeInstances",
        "awsRegion": "us-east-1",
        "readOnly": True,
        "errorCode": None,
    }
    record.update(overrides)
    return record


def put_cloudtrail_file(s3, bucket, key, records):
    """Write `records` as a gzipped CloudTrail delivery file at `key`."""
    body = gzip.compress(json.dumps({"Records": records}).encode())
    s3.put_object(Bucket=bucket, Key=key, Body=body)


def cloudtrail_key(region="us-east-1", date="2026/07/01", name="file", account="123"):
    return f"AWSLogs/{account}/CloudTrail/{region}/{date}/{name}.json.gz"
