"""Errors and write/change operations only -- the noisy read-only console
traffic (DescribeX, ListY, GetZ) is the bulk of most CloudTrail volume and
rarely what an investigation cares about."""
SUBPATH = "errors_and_writes/"


def matches(record):
    if record.get("errorCode") or record.get("errorMessage"):
        return True
    # readOnly is a string "true"/"false" (or absent) in raw CloudTrail JSON.
    return str(record.get("readOnly", "")).lower() == "false"
