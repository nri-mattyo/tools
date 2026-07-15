#!/usr/bin/env bash
#
# filter-stale-ecr-images.sh
#
# Read ECR image JSONL (from describe-ecr-images.sh, or stdin) and emit only the
# images that are "stale": created more than N days ago AND last pulled more
# than M days ago. Output is JSONL.
#
# Usage:
#   ./filter-stale-ecr-images.sh [--input FILE] [--output FILE] \
#       [--created-days N] [--pulled-days M] [--include-never-pulled]
#
# Defaults: --created-days 30  --pulled-days 21
#
# By default, images that were NEVER pulled (no lastRecordedPullTime) are
# EXCLUDED, because we cannot prove they were "last pulled over M days ago".
# Pass --include-never-pulled to treat never-pulled (but old enough) images as
# stale too.
#
# Examples:
#   ./describe-ecr-images.sh | ./filter-stale-ecr-images.sh
#   ./filter-stale-ecr-images.sh --input ecr-images.jsonl --output stale.jsonl
#   ./filter-stale-ecr-images.sh --input ecr-images.jsonl --include-never-pulled
#
set -euo pipefail

INPUT=""
OUTPUT=""
CREATED_DAYS=30
PULLED_DAYS=21
INCLUDE_NEVER_PULLED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)        INPUT="$2";        shift 2 ;;
    --output)       OUTPUT="$2";       shift 2 ;;
    --created-days) CREATED_DAYS="$2"; shift 2 ;;
    --pulled-days)  PULLED_DAYS="$2";  shift 2 ;;
    --include-never-pulled) INCLUDE_NEVER_PULLED=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//;s/^ //'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

run_filter() {
  CREATED_DAYS="$CREATED_DAYS" PULLED_DAYS="$PULLED_DAYS" \
  INCLUDE_NEVER_PULLED="$INCLUDE_NEVER_PULLED" \
  python3 - "$@" <<'PY'
import sys, os, json
from datetime import datetime, timezone, timedelta

created_days = int(os.environ["CREATED_DAYS"])
pulled_days  = int(os.environ["PULLED_DAYS"])
include_never = os.environ["INCLUDE_NEVER_PULLED"] == "1"

now = datetime.now(timezone.utc)
created_cutoff = now - timedelta(days=created_days)
pulled_cutoff  = now - timedelta(days=pulled_days)

def parse(ts):
    # datetime.fromisoformat handles offsets like -05:00; normalize trailing Z.
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))

src = open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin
for line in src:
    line = line.strip()
    if not line:
        continue
    img = json.loads(line)

    pushed = img.get("imagePushedAt")
    if not pushed or parse(pushed) >= created_cutoff:
        continue  # not old enough

    pulled = img.get("lastRecordedPullTime")
    if pulled:
        if parse(pulled) >= pulled_cutoff:
            continue  # pulled too recently
    else:
        if not include_never:
            continue  # never pulled -> excluded by default

    print(json.dumps(img))
PY
}

ARGS=()
[[ -n "$INPUT" ]] && ARGS+=("$INPUT")

if [[ -n "$OUTPUT" ]]; then
  run_filter "${ARGS[@]+"${ARGS[@]}"}" > "$OUTPUT"
  echo "Wrote $(wc -l < "$OUTPUT" | tr -d ' ') stale images to $OUTPUT" >&2
else
  run_filter "${ARGS[@]+"${ARGS[@]}"}"
fi
