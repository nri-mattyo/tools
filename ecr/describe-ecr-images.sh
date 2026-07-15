#!/usr/bin/env bash
#
# describe-ecr-images.sh
#
# Describe every image in every ECR repository in the current AWS account/region
# and emit them as JSON Lines (one image JSON object per line). Each object is
# augmented with a "repositoryName" field so images can be traced to their repo.
#
# Usage:
#   ./describe-ecr-images.sh [--region REGION] [--profile PROFILE] [--output FILE]
#
# Examples:
#   ./describe-ecr-images.sh
#   ./describe-ecr-images.sh --region us-west-2
#   ./describe-ecr-images.sh --profile prod --output images.jsonl
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

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: aws CLI not found on PATH." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required by this script." >&2
  exit 1
fi

aws_run() { aws "$@" ${AWS_ARGS[@]+"${AWS_ARGS[@]}"}; }

emit_jsonl() {
  # Get all repository names (auto-paginated).
  local repos
  repos=$(aws_run ecr describe-repositories --output json | jq -r '.repositories[].repositoryName')

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    # describe-images auto-paginates. Tag each image detail with its repo name.
    # An empty repo yields an empty imageDetails array (nothing emitted).
    aws_run ecr describe-images --repository-name "$repo" --output json \
      | jq -c --arg repo "$repo" '.imageDetails[] | {repositoryName: $repo} + .'
  done <<< "$repos"
}

if [[ -n "$OUTPUT" ]]; then
  emit_jsonl > "$OUTPUT"
  echo "Wrote $(wc -l < "$OUTPUT" | tr -d ' ') images to $OUTPUT" >&2
else
  emit_jsonl
fi
