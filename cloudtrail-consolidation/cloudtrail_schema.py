"""The fixed CloudTrail record schema used for both the Parquet output and the
Athena CREATE TABLE DDL. Mirrors AWS's own documented CloudTrail Athena schema
(https://docs.aws.amazon.com/athena/latest/ug/create-cloudtrail-table-partition-projection.html)
so existing json_extract_scalar()-style queries against requestParameters /
responseElements / userIdentity etc. keep working unchanged.

Every column is STRING. The nested/variable-shape fields (userIdentity,
requestParameters, ...) are JSON-encoded text rather than native structs --
CloudTrail record shape varies wildly by event, and a single flat schema is
what makes one Parquet dataset able to hold every event type without per-event
schema drift.
"""
import json

# Kept as-is from the raw record (already scalar strings/bools in CloudTrail JSON).
SCALAR_FIELDS = [
    "eventVersion", "eventTime", "eventSource", "eventName", "awsRegion",
    "sourceIPAddress", "userAgent", "errorCode", "errorMessage", "requestID",
    "eventID", "readOnly", "eventType", "apiVersion", "recipientAccountId",
    "sharedEventID", "vpcEndpointId", "eventCategory", "managementEvent",
    "sessionCredentialFromConsole",
]

# JSON-encoded because they're nested objects/arrays or vary by event type.
JSON_FIELDS = [
    "userIdentity", "requestParameters", "responseElements", "additionalEventData",
    "resources", "serviceEventDetails", "addendum", "edgeDeviceDetails", "tlsDetails",
]

# lower-cased column name -> source record field name, in DDL column order.
COLUMNS = [(f.lower(), f) for f in SCALAR_FIELDS + JSON_FIELDS]

# Not part of the CloudTrail record itself -- convert.py stamps this on every
# row with the full s3://bucket/key path the record was parsed from. Lets you
# audit that every source file is represented, and spot cross-bucket
# duplicates (e.g. two separate Trails delivering the same underlying event,
# recognizable by matching eventid but different orig_file) without needing
# anything outside the Parquet data itself.
ORIG_FILE_COLUMN = "orig_file"

# Full DDL column list, in order: the CloudTrail fields, then orig_file.
DDL_COLUMNS = [c for c, _ in COLUMNS] + [ORIG_FILE_COLUMN]

PARTITION_COLUMNS = ["year", "month", "day"]


def flatten_record(record):
    """One raw CloudTrail record dict -> a flat dict of our fixed STRING columns
    (missing fields become None -> null in the resulting Parquet column)."""
    out = {}
    for col, field in COLUMNS:
        if field in SCALAR_FIELDS:
            v = record.get(field)
            if v is None:
                out[col] = None
            elif isinstance(v, bool):
                out[col] = "true" if v else "false"  # match CloudTrail's own lowercase JSON text
            else:
                out[col] = str(v)
        else:
            v = record.get(field)
            out[col] = json.dumps(v) if v is not None else None
    return out


def partition_for(event_time):
    """"2026-07-03T14:22:10Z" -> {"year": "2026", "month": "202607", "day": "20260703"}."""
    # CloudTrail eventTime is always UTC, formatted YYYY-MM-DDTHH:MM:SSZ.
    date_part = event_time[:10]  # "2026-07-03"
    y, m, d = date_part.split("-")
    return {"year": y, "month": f"{y}{m}", "day": f"{y}{m}{d}"}
