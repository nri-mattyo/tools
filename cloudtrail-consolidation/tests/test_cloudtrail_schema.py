"""cloudtrail_schema.py: record flattening (the fixed Athena-compatible
schema) and date-partition derivation."""
import json

from cloudtrail_schema import DDL_COLUMNS, ORIG_FILE_COLUMN, flatten_record, partition_for


def test_boolean_fields_become_lowercase_strings_not_python_repr():
    """Regression: str(True) is "True" in Python, but CloudTrail's own JSON
    convention (and Athena queries like WHERE readonly='false') expects
    lowercase "true"/"false"."""
    row_true = flatten_record({"eventName": "X", "readOnly": True})
    row_false = flatten_record({"eventName": "X", "readOnly": False})
    assert row_true["readonly"] == "true"
    assert row_false["readonly"] == "false"


def test_missing_fields_become_none():
    row = flatten_record({"eventName": "X"})
    assert row["errorcode"] is None
    assert row["useridentity"] is None


def test_scalar_fields_are_stringified():
    row = flatten_record({"eventName": "X", "apiVersion": 2})
    assert row["apiversion"] == "2"


def test_nested_fields_are_json_encoded():
    record = {
        "eventName": "X",
        "userIdentity": {"type": "IAMUser", "arn": "arn:aws:iam::123:user/me"},
        "resources": [{"ARN": "arn:aws:s3:::bucket", "type": "AWS::S3::Object"}],
    }
    row = flatten_record(record)
    assert json.loads(row["useridentity"]) == record["userIdentity"]
    assert json.loads(row["resources"]) == record["resources"]


def test_partition_for_derives_year_month_day():
    assert partition_for("2026-07-03T14:22:10Z") == {"year": "2026", "month": "202607", "day": "20260703"}


def test_orig_file_column_is_not_derived_from_the_record():
    """orig_file is stamped on by convert.py after flatten_record(), not
    pulled from the CloudTrail record itself -- flatten_record() shouldn't
    produce it, but it must still be part of the DDL column list."""
    row = flatten_record({"eventName": "X"})
    assert ORIG_FILE_COLUMN not in row
    assert ORIG_FILE_COLUMN in DDL_COLUMNS
    assert DDL_COLUMNS[-1] == ORIG_FILE_COLUMN, "orig_file should be the last DDL column"
