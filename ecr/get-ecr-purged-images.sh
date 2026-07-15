#!/usr/bin/env bash
#
# get-ecr-purged-images.sh
#
# List ECR images that were purged by lifecycle-rule runs, sourced from
# CloudTrail "PolicyExecutionEvent" events (eventSource ecr.amazonaws.com).
# Output is JSON Lines: one line per purged image.
#
# Each lifecycle run is logged as a PolicyExecutionEvent whose
# serviceEventDetails.lifecycleEventImageActions[] holds the images that run
# deleted (empty when the run purged nothing). This script flattens those
# actions across all runs in the window.
#
# Note: CloudTrail retains management events for ~90 days, so --days cannot
# look back further than that without a configured trail / CloudTrail Lake.
#
# Each emitted line:
#   {"eventTime": "...", "eventID": "...", "repositoryName": "...",
#    "rulePriority": N, ...all fields from the image action...}
#
# Usage:
#   ./get-ecr-purged-images.sh [--days N] [--region REGION] [--profile PROFILE] [--output FILE]
#
# Defaults: --days 30
#
set -euo pipefail

DAYS=30
REGION=""
PROFILE=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)    DAYS="$2";    shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --output)  OUTPUT="$2";  shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//;s/^ //'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

AWS_ARGS=()
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")

command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found." >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

aws_run() { aws "$@" ${AWS_ARGS[@]+"${AWS_ARGS[@]}"}; }

# Portable "N days ago" in UTC ISO8601 (works with BSD/macOS and GNU date).
start_time() {
  if date -u -v-1d >/dev/null 2>&1; then
    date -u -v-"${DAYS}"d '+%Y-%m-%dT%H:%M:%SZ'      # BSD/macOS
  else
    date -u -d "${DAYS} days ago" '+%Y-%m-%dT%H:%M:%SZ'  # GNU
  fi
}

emit_jsonl() {
  local start token page
  start="$(start_time)"
  token=""

  # Manual pagination with pacing to stay under CloudTrail's LookupEvents rate.
  while :; do
    if [[ -n "$token" ]]; then
      page=$(aws_run cloudtrail lookup-events \
        --lookup-attributes AttributeKey=EventName,AttributeValue=PolicyExecutionEvent \
        --start-time "$start" --max-results 50 --next-token "$token" --output json)
    else
      page=$(aws_run cloudtrail lookup-events \
        --lookup-attributes AttributeKey=EventName,AttributeValue=PolicyExecutionEvent \
        --start-time "$start" --max-results 50 --output json)
    fi

    # Flatten each run's image actions into one line per purged image.
    jq -c '
      .Events[].CloudTrailEvent | fromjson
      | . as $e
      | $e.serviceEventDetails as $d
      | $d.lifecycleEventImageActions[]?
      | {
          eventTime: $e.eventTime,
          eventID: $e.eventID,
          repositoryName: $d.repositoryName
        } + .
    ' <<<"$page"

    token=$(jq -r '.NextToken // empty' <<<"$page")
    [[ -z "$token" ]] && break
    sleep 1   # pace pagination to avoid ThrottlingException
  done
}

if [[ -n "$OUTPUT" ]]; then
  emit_jsonl > "$OUTPUT"
  echo "Wrote $(wc -l < "$OUTPUT" | tr -d ' ') purged images to $OUTPUT" >&2
else
  emit_jsonl
fi
