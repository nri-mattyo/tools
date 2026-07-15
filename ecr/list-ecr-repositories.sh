#!/usr/bin/env bash
#
# list-ecr-repositories.sh
#
# List all ECR repositories in the current AWS account/region and emit them
# as JSON Lines (one JSON object per line).
#
# Usage:
#   ./list-ecr-repositories.sh [--region REGION] [--profile PROFILE] [--output FILE]
#
# Examples:
#   ./list-ecr-repositories.sh
#   ./list-ecr-repositories.sh --region us-west-2
#   ./list-ecr-repositories.sh --profile prod --output repos.jsonl
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

# Build common AWS CLI args.
AWS_ARGS=()
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: aws CLI not found on PATH." >&2
  exit 1
fi

# describe-repositories paginates automatically; --output json returns the full
# structure, which we convert to JSONL with the AWS CLI's built-in jq-like
# transform. We use jq if available, otherwise fall back to python.
emit_jsonl() {
  if command -v jq >/dev/null 2>&1; then
    aws ecr describe-repositories ${AWS_ARGS[@]+"${AWS_ARGS[@]}"} --output json \
      | jq -c '.repositories[]'
  else
    aws ecr describe-repositories ${AWS_ARGS[@]+"${AWS_ARGS[@]}"} --output json \
      | python3 -c 'import sys, json; [print(json.dumps(r)) for r in json.load(sys.stdin)["repositories"]]'
  fi
}

if [[ -n "$OUTPUT" ]]; then
  emit_jsonl > "$OUTPUT"
  echo "Wrote $(wc -l < "$OUTPUT" | tr -d ' ') repositories to $OUTPUT" >&2
else
  emit_jsonl
fi
