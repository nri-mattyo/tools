#!/usr/bin/env bash
# Tests for root-module discovery and target resolution in lib/common.sh:
# discover_root_modules and collect_module_dirs (ALL / DIRS / default cwd).
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
. "$TF_DIR/lib/common.sh"

test_discovery_finds_backend_modules_only() {
  mkdir -p a b c nested/deep
  printf 'terraform {\n  backend "s3" {}\n}\n' > a/main.tf
  printf 'terraform {\n  backend "s3" {}\n}\n' > b/backend.tf
  printf 'resource "x" "y" {}\n' > c/main.tf
  printf 'terraform {\n  backend "s3" {}\n}\n' > nested/deep/main.tf
  local out
  out="$(discover_root_modules)"
  assert_contains "$out" "./a" "finds module a"
  assert_contains "$out" "./b" "finds module b (backend in a differently named file)"
  assert_contains "$out" "./nested/deep" "finds nested module"
  assert_not_contains "$out" "./c" "skips module without an s3 backend"
}

test_discovery_dedupes_multi_file_modules() {
  mkdir -p dup
  printf 'terraform {\n  backend "s3" {}\n}\n' > dup/main.tf
  printf '# also mentions backend "s3" here\n' > dup/notes.tf
  assert_eq 1 "$(discover_root_modules | grep -c '^\./dup$')" "one entry per module dir"
}

test_collect_defaults_to_cwd() {
  ALL=false; DIRS=()
  collect_module_dirs
  assert_eq 1 "${#MODULE_DIRS[@]}" "one target"
  assert_eq "." "${MODULE_DIRS[0]}" "default is cwd"
}

test_collect_uses_explicit_dirs() {
  ALL=false; DIRS=(x/y z)
  collect_module_dirs
  assert_eq "x/y z" "${MODULE_DIRS[*]}" "explicit dirs preserved in order"
}

test_collect_all_discovers() {
  mkdir -p m1 m2
  printf 'terraform {\n  backend "s3" {}\n}\n' > m1/main.tf
  printf 'terraform {\n  backend "s3" {}\n}\n' > m2/main.tf
  ALL=true; DIRS=()
  collect_module_dirs > /dev/null # discard the "discovered N" info line
  assert_eq 2 "${#MODULE_DIRS[@]}" "discovered both modules"
}

test_collect_all_with_no_modules_errors() {
  local out rc
  out="$( (ALL=true; DIRS=(); collect_module_dirs) 2>&1 )"; rc=$?
  assert_rc 1 "$rc" "exits 1 when nothing to discover"
  assert_contains "$out" "no root modules" "explains the failure"
}

run_test test_discovery_finds_backend_modules_only
run_test test_discovery_dedupes_multi_file_modules
run_test test_collect_defaults_to_cwd
run_test test_collect_uses_explicit_dirs
run_test test_collect_all_discovers
run_test test_collect_all_with_no_modules_errors
finish
