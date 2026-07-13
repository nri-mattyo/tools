#!/usr/bin/env bash
# Every shell script in the toolset must at least parse (bash -n). Catches
# accidental bashisms/typos in files the other tests don't execute directly.
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

test_all_scripts_parse() {
  local f
  for f in "$TF_DIR"/*.sh "$TF_DIR"/lib/*.sh "$TESTS_DIR"/*.sh; do
    if bash -n "$f" 2>/dev/null; then
      pass
    else
      fail "does not parse: $f"
    fi
  done
}

run_test test_all_scripts_parse
finish
