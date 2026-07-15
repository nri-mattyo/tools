"""S3 data-plane events (GetObject/PutObject/... on individual objects) split
out to their own dataset -- these can dwarf every other event source in
volume when S3 data-event logging is enabled, so keeping them out of the
general-purpose dataset keeps that one fast to query."""
SUBPATH = "s3_data_events/"


def matches(record):
    return record.get("eventSource") == "s3.amazonaws.com" and record.get("eventCategory") == "Data"
