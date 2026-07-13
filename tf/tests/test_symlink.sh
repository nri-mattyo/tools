#!/usr/bin/env bash
# The entry scripts are meant to be symlinked onto PATH (e.g. tools/bin/), so
# BASH_SOURCE[0] is the symlink, not the real file. The inline abspath()
# resolver must follow the link chain back to the repo so lib/common.sh loads.
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

test_absolute_symlink() {
  make_aws_stub ok
  make_tf_stub ok
  mkdir -p bin mod
  ln -s "$TF_DIR/init.sh" bin/init.sh
  local out rc
  out="$(PATH="$SANDBOX/stub:$PATH" bin/init.sh mod < /dev/null 2>&1)"; rc=$?
  assert_rc 0 "$rc" "runs through an absolute symlink"
  assert_not_contains "$out" "No such file or directory" "lib/common.sh found"
  assert_contains "$out" "successfully initialized"
}

test_relative_symlink_chain() {
  # bin/plan.sh -> ../real/plan.sh -> (absolute) $TF_DIR/plan.sh:
  # a relative link that itself points at another link.
  make_aws_stub ok
  make_tfdata_module mod
  mkdir -p bin real
  ln -s "$TF_DIR/plan.sh" real/plan.sh
  ln -s ../real/plan.sh bin/plan.sh
  local out rc
  out="$(PATH="$SANDBOX/stub:$PATH" bin/plan.sh --no-apply mod < /dev/null 2>&1)"; rc=$?
  assert_rc 0 "$rc" "runs through a relative symlink chain"
  assert_not_contains "$out" "command not found" "lib functions loaded"
  assert_contains "$out" "Plan: 1 to create" "full plan flow works via symlink"
}

test_symlinked_apply_finds_sibling_scripts() {
  make_aws_stub ok
  make_tfdata_module mod
  mkdir -p bin
  ln -s "$TF_DIR/plan.sh" bin/plan.sh
  ln -s "$TF_DIR/apply.sh" bin/apply.sh
  PATH="$SANDBOX/stub:$PATH" bin/plan.sh --no-apply mod < /dev/null > /dev/null 2>&1
  local out rc
  out="$(PATH="$SANDBOX/stub:$PATH" bin/apply.sh -y mod < /dev/null 2>&1)"; rc=$?
  assert_rc 0 "$rc" "apply works through a symlink"
  assert_contains "$out" "Apply complete"
}

test_direct_invocation_still_works() {
  # No symlink involved: abspath must be a no-op for a regular file.
  make_aws_stub ok
  make_tf_stub ok
  mkdir -p mod
  local out rc
  out="$(PATH="$SANDBOX/stub:$PATH" "$TF_DIR/init.sh" mod < /dev/null 2>&1)"; rc=$?
  assert_rc 0 "$rc" "direct path invocation unaffected"
  assert_contains "$out" "successfully initialized"
}

run_test test_absolute_symlink
run_test test_relative_symlink_chain
run_test test_symlinked_apply_finds_sibling_scripts
run_test test_direct_invocation_still_works
finish
