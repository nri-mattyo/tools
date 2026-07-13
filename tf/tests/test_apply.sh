#!/usr/bin/env bash
# Integration tests for apply.sh (and the plan.sh --auto-apply path) against a
# real terraform binary — builtin terraform_data resource, local state, stubbed
# aws CLI. Covers the apply loop, metadata recording, and the guard rails.
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

run_plan()  { OUT="$(PATH="$SANDBOX/stub:$PATH" "$TF_DIR/plan.sh"  "$@" < /dev/null 2>&1)"; RC=$?; }
run_apply() { OUT="$(PATH="$SANDBOX/stub:$PATH" "$TF_DIR/apply.sh" "$@" < /dev/null 2>&1)"; RC=$?; }

# plan_once <dir> — produce a saved plan without applying
plan_once() { run_plan --no-apply "$1"; }

test_apply_yes_applies_latest_plan() {
  make_aws_stub ok
  make_tfdata_module mod
  plan_once mod
  run_apply -y mod
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Plan: 1 to create" "summary shown before applying"
  assert_contains "$OUT" "Apply complete" "terraform applied"
  assert_file mod/terraform.tfstate "state written"

  local meta="mod/.terraform/tfplans/latest.json"
  assert_eq 0 "$(jq -r '.apply_exit' "$meta")" "apply exit recorded"
  case "$(jq -r '.applied_at' "$meta")" in
    null|'') fail "applied_at not recorded" ;;
    *) pass ;;
  esac
  assert_file "$(jq -r '.apply_log' "$meta")" "versioned apply log"
}

test_apply_prompt_defaults_to_not_applying() {
  make_aws_stub ok
  make_tfdata_module mod
  plan_once mod
  run_apply mod # no -y, non-tty stdin -> "no"
  assert_rc 0 "$RC"
  assert_contains "$OUT" "not applying" "declined apply reported"
  assert_no_file mod/terraform.tfstate "nothing was applied"
}

test_apply_stale_plan_fails_clearly() {
  make_aws_stub ok
  make_tfdata_module mod
  plan_once mod
  run_apply -y mod
  run_apply -y mod # same plan again: state serial moved on
  assert_rc 1 "$RC"
  assert_contains "$OUT" "already applied" "warns before retrying an applied plan"
  assert_contains "$OUT" "stale" "explains the stale-plan failure"
  assert_contains "$OUT" "re-run plan.sh" "points at the fix"
}

test_apply_no_changes_is_a_noop() {
  make_aws_stub ok
  make_tfdata_module mod
  plan_once mod
  run_apply -y mod
  plan_once mod # fresh plan of the applied module: no changes
  run_apply -y mod
  assert_rc 0 "$RC"
  assert_contains "$OUT" "nothing to apply"
}

test_apply_without_saved_plan_warns() {
  make_aws_stub ok
  mkdir -p empty
  run_apply -y empty
  assert_rc 1 "$RC"
  assert_contains "$OUT" "no saved plan" "asks for plan.sh first"
}

test_apply_specific_plan_file() {
  make_aws_stub ok
  make_tfdata_module mod
  plan_once mod
  run_apply -y --plan "$(ls mod/.terraform/tfplans/*.tfplan)"
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Apply complete"
}

test_apply_missing_plan_file_flag() {
  make_aws_stub ok
  run_apply --plan does-not-exist.tfplan
  assert_rc 1 "$RC"
  assert_contains "$OUT" "no such plan file"
}

test_plan_auto_apply_flag() {
  make_aws_stub ok
  make_tfdata_module mod
  run_plan --auto-apply mod
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Apply complete" "plan.sh --auto-apply applies in one shot"
  assert_file mod/terraform.tfstate "state written"
  assert_eq 0 "$(jq -r '.apply_exit' mod/.terraform/tfplans/latest.json)" "apply recorded on the run metadata"
}

run_test test_apply_yes_applies_latest_plan
run_test test_apply_prompt_defaults_to_not_applying
run_test test_apply_stale_plan_fails_clearly
run_test test_apply_no_changes_is_a_noop
run_test test_apply_without_saved_plan_warns
run_test test_apply_specific_plan_file
run_test test_apply_missing_plan_file_flag
run_test test_plan_auto_apply_flag
finish
