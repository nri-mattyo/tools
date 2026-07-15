"""
Read-only full list-objects-v2 dump of CloudTrail buckets, written as
gzipped JSON Lines (one object record per line). Each entry in ACCOUNTS is
listed under its own AWS profile since each bucket lives in a different
account.
"""
import gzip
import json
import sys

import boto3

ACCOUNTS = [
    ("nri-develop", "aws-cloudtrail-logs-381492092437-74dbd159"),  # api-events
    ("nri-develop", "nri-cloudtrail-logs-381492092437"),            # main-cloudtrail
    ("nri-customer", "nri-cloudtrail-logs-637423466983"),           # main-cloudtrail
    ("newton", "aws-cloudtrail-logs-293034550673-c21dd2f3"),        # management-events
]

def iter_objects(s3, bucket):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket):
        for obj in page.get("Contents", []):
            yield obj

def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "all_cloudtrail_objects.jsonl.gz"
    accounts = ACCOUNTS
    if len(sys.argv) > 2:
        selected = set(sys.argv[2].split(","))
        accounts = [(p, b) for p, b in ACCOUNTS if b in selected]

    total = 0
    with gzip.open(out_path, "wt") as f:
        for profile, bucket in accounts:
            session = boto3.Session(profile_name=profile)
            s3 = session.client("s3", region_name="us-east-1")
            count = 0
            for obj in iter_objects(s3, bucket):
                record = {
                    "bucket": bucket,
                    "key": obj["Key"],
                    "size": obj["Size"],
                    "last_modified": obj["LastModified"].isoformat(),
                    "etag": obj.get("ETag"),
                    "storage_class": obj.get("StorageClass"),
                }
                f.write(json.dumps(record) + "\n")
                count += 1
                total += 1
                if count % 50000 == 0:
                    print(f"{bucket}: {count} objects so far", file=sys.stderr)
            print(f"{bucket}: {count} objects total", file=sys.stderr)
    print(f"TOTAL objects written: {total} -> {out_path}", file=sys.stderr)

if __name__ == "__main__":
    main()
