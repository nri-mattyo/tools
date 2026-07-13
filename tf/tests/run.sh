#!/usr/bin/env bash
# run.sh — zero-dependency test runner for the tf wrapper scripts.
# Executes every test_*.sh in this directory; each file prints its own
# per-test results and exits nonzero on any failure.
#
# Usage:
#   ./run.sh              # run everything
#   ./run.sh summary init # run only test_summary.sh and test_init.sh
#
# Requirements: bash, jq, terraform (any recent 1.x; the integration tests use
# only the builtin terraform_data resource — no cloud credentials, no network).
set -o pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

files=()
if [ $# -gt 0 ]; then
  for name in "$@"; do
    f="$TESTS_DIR/test_${name#test_}"
    f="${f%.sh}.sh"
    if [ -f "$f" ]; then
      files+=("$f")
    else
      echo "error: no such test file: $f" >&2
      exit 2
    fi
  done
else
  for f in "$TESTS_DIR"/test_*.sh; do files+=("$f"); done
fi

overall=0
failed=""
for f in "${files[@]}"; do
  echo "===== $(basename "$f" .sh)"
  if ! bash "$f"; then
    overall=1
    failed="$failed $(basename "$f" .sh)"
  fi
done

echo ""
if [ "$overall" -eq 0 ]; then
  echo "ALL TEST FILES PASSED"
else
  echo "FAILED:$failed"
fi
exit "$overall"
