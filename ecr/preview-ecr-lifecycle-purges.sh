#!/usr/bin/env bash
#
# preview-ecr-lifecycle-purges.sh
#
# For every ECR repository that has a lifecycle policy, run a lifecycle policy
# preview and emit the images the policy matches for expiry as JSON Lines.
#
# IMPORTANT: this shows images that are CURRENTLY PRESENT and match the live
# rules -- i.e. what the NEXT lifecycle run will purge. It cannot list images
# already deleted by past runs: ECR does not expose lifecycle deletion history
# through any public API or CloudTrail (the console's history view uses a
# private, console-only API). To retain future purges, capture the EventBridge
# "ECR Image Action" DELETE event.
#
# Each emitted line:
#   {"repositoryName": "...", "imageDigest": "...", "imageTags": [...],
#    "imagePushedAt": "...", "appliedRulePriority": N}
#
# Usage:
#   ./preview-ecr-lifecycle-purges.sh [--region REGION] [--profile PROFILE] [--output FILE]
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
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

AWS_ARGS=()
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")

command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found." >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

aws_run() { aws "$@" ${AWS_ARGS[@]+"${AWS_ARGS[@]}"}; }

emit_jsonl() {
  local repos repo st
  repos=$(aws_run ecr describe-repositories --output json | jq -r '.repositories[].repositoryName')

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    # Skip repos with no lifecycle policy (nothing to preview).
    aws_run ecr get-lifecycle-policy --repository-name "$repo" >/dev/null 2>&1 || continue

    # Kick off a fresh preview. If one is already in progress this errors; ignore.
    aws_run ecr start-lifecycle-policy-preview --repository-name "$repo" >/dev/null 2>&1 || true

    # Poll until the preview finishes.
    st=""
    for _ in $(seq 1 30); do
      st=$(aws_run ecr get-lifecycle-policy-preview --repository-name "$repo" --output json 2>/dev/null | jq -r '.status // "UNKNOWN"')
      [[ "$st" == "COMPLETE" || "$st" == "FAILED" ]] && break
      sleep 1
    done

    if [[ "$st" != "COMPLETE" ]]; then
      echo "warn: preview for $repo ended in status=$st; skipping" >&2
      continue
    fi

    aws_run ecr get-lifecycle-policy-preview --repository-name "$repo" --output json 2>/dev/null \
      | jq -c --arg repo "$repo" '.previewResults[] | {
          repositoryName: $repo,
          imageDigest: .imageDigest,
          imageTags: (.imageTags // []),
          imagePushedAt: .imagePushedAt,
          appliedRulePriority: .appliedRulePriority
        }'
  done <<< "$repos"
}

if [[ -n "$OUTPUT" ]]; then
  emit_jsonl > "$OUTPUT"
  echo "Wrote $(wc -l < "$OUTPUT" | tr -d ' ') matching images to $OUTPUT" >&2
else
  emit_jsonl
fi
