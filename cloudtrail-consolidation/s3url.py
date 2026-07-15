"""s3:// URL parsing and single-wildcard prefix expansion.

Accepts either an `s3://bucket/prefix` URL or a separate bucket + prefix pair
everywhere a location is needed (--from/--to on the CLI). A prefix containing
exactly one `/*/` segment (e.g. the region slot in a CloudTrail path) is
expanded into the real common prefixes found in S3, using list_objects_v2 with
Delimiter="/" -- the same trick the AWS console's "folder" view uses.
"""
import re

WILDCARD_RE = re.compile(r"/\*/")


def parse_s3_url(url):
    """s3://bucket/some/prefix/ -> ("bucket", "some/prefix/")."""
    if not url.startswith("s3://"):
        raise ValueError(f"not an s3:// url: {url!r}")
    rest = url[len("s3://"):]
    bucket, _, prefix = rest.partition("/")
    if not bucket:
        raise ValueError(f"missing bucket in s3 url: {url!r}")
    return bucket, prefix


def to_s3_url(bucket, prefix):
    return f"s3://{bucket}/{prefix}"


def has_wildcard(prefix):
    return "/*/" in prefix


def split_wildcard(prefix):
    """"a/b/*/2026/07/" -> ("a/b/", "2026/07/").

    Only a single `/*/` is supported -- every example in the spec has exactly
    one (the region slot). A second wildcard would need recursive expansion
    we haven't built, so fail loudly instead of silently doing the wrong thing.
    """
    matches = list(WILDCARD_RE.finditer(prefix))
    if not matches:
        raise ValueError(f"no wildcard segment in prefix: {prefix!r}")
    if len(matches) > 1:
        raise NotImplementedError(
            f"only one '/*/' wildcard segment is supported, found {len(matches)} in {prefix!r}")
    m = matches[0]
    before = prefix[:m.start() + 1]  # keep trailing "/"
    after = prefix[m.end():]
    return before, after


def expand_wildcard(s3_client, bucket, prefix):
    """Yield concrete prefixes for a prefix containing one `/*/` segment.

    e.g. bucket=X, prefix="AWSLogs/123/CloudTrail/*/2026/07/01/" yields
    "AWSLogs/123/CloudTrail/us-east-1/2026/07/01/",
    "AWSLogs/123/CloudTrail/us-west-2/2026/07/01/", ... for every region
    that actually has a common prefix under CloudTrail/.
    """
    before, after = split_wildcard(prefix)
    token = None
    while True:
        kwargs = {"Bucket": bucket, "Prefix": before, "Delimiter": "/"}
        if token:
            kwargs["ContinuationToken"] = token
        resp = s3_client.list_objects_v2(**kwargs)
        for cp in resp.get("CommonPrefixes", []):
            yield cp["Prefix"] + after
        if not resp.get("IsTruncated"):
            break
        token = resp.get("NextContinuationToken")


def resolve_prefixes(s3_client, bucket, prefix):
    """Return the list of concrete prefixes to list objects under -- expanding
    a wildcard if present, or just [prefix] if not."""
    if has_wildcard(prefix):
        return list(expand_wildcard(s3_client, bucket, prefix))
    return [prefix]
