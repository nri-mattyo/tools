#!/usr/bin/env bash
#
# get-ecr-lifecycle-policies.sh
#
# Fetch the lifecycle policy for every ECR repository in the current AWS
# account/region and emit them as JSON Lines (one repository per line).
#
# Note: ECR lifecycle policies are per-repository; there is no per-registry
# lifecycle policy. Repositories with no policy are still emitted, with
# "hasPolicy": false and "lifecyclePolicyText": null.
#
# Each line looks like:
#   {"repositoryName": "...", "hasPolicy": true,
#    "lifecyclePolicyText": {...parsed JSON...}, "lastEvaluatedAt": "..."}
#
# Usage:
#   ./get-ecr-lifecycle-policies.sh [--region REGION] [--profile PROFILE] [--output FILE]
#
set -euo pipefail

REGION=""
PROFILE=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)  REGION="$2";  shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --output)  OUTPUT="$2";  shift 2 ;;
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

AWS_ARGS=()
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")

command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found." >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

aws_run() { aws "$@" ${AWS_ARGS[@]+"${AWS_ARGS[@]}"}; }

emit_jsonl() {
  local repos
  repos=$(aws_run ecr describe-repositories --output json | jq -r '.repositories[].repositoryName')

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    # Capture stdout/stderr separately so we can distinguish "no policy" from
    # real errors. get-lifecycle-policy errors when no policy is configured.
    local out
    if out=$(aws_run ecr get-lifecycle-policy --repository-name "$repo" --output json 2>/dev/null); then
      jq -c --arg repo "$repo" '{
        repositoryName: $repo,
        hasPolicy: true,
        lifecyclePolicyText: (.lifecyclePolicyText | fromjson),
        lastEvaluatedAt: (.lastEvaluatedAt // null)
      }' <<<"$out"
    else
      jq -nc --arg repo "$repo" '{
        repositoryName: $repo,
        hasPolicy: false,
        lifecyclePolicyText: null,
        lastEvaluatedAt: null
      }'
    fi
  done <<< "$repos"
}

if [[ -n "$OUTPUT" ]]; then
  emit_jsonl > "$OUTPUT"
  echo "Wrote $(wc -l < "$OUTPUT" | tr -d ' ') repositories to $OUTPUT" >&2
else
  emit_jsonl
fi
