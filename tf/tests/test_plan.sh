#!/usr/bin/env bash
# Integration tests for plan.sh against a real terraform binary. The module
# uses only the builtin terraform_data resource (local state, no providers to
# download) and the aws CLI is stubbed, so no credentials or network are needed.
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

# run_plan [args...] — invoke plan.sh with the stubbed aws first on PATH,
# stdin closed (so the apply prompt answers "no"). Sets OUT and RC.
run_plan() {
  OUT="$(PATH="$SANDBOX/stub:$PATH" "$TF_DIR/plan.sh" "$@" < /dev/null 2>&1)"
  RC=$?
}

test_plan_produces_versioned_artifacts() {
  make_aws_stub ok
  make_tfdata_module mod
  run_plan --no-apply mod
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Plan: 1 to create, 0 to update, 0 to destroy, 0 to replace" "quick summary header"
  assert_contains "$OUT" "[create] terraform_data.hello" "quick summary resource line"

  local plan
  plan="$(ls mod/.terraform/tfplans/*.tfplan 2>/dev/null | head -1)"
  assert_file "$plan" "versioned .tfplan"
  assert_file "${plan}.log" "versioned stdout/stderr log"
  assert_file "${plan}.json" "versioned plan JSON"
  assert_file "${plan%.tfplan}.run.json" "versioned run metadata"
  assert_file "mod/.terraform/tfplans/latest.json" "latest-run pointer"
  assert_file "mod/.terraform/latest.tfplan.json" "back-compat copy for plan-report scripts"
}

test_plan_run_metadata_contents() {
  make_aws_stub ok
  make_tfdata_module mod
  run_plan --no-apply mod
  local meta="mod/.terraform/tfplans/latest.json"
  assert_eq 2     "$(jq -r '.exit_code' "$meta")"      "detailed exit code recorded"
  assert_eq true  "$(jq -r '.has_changes' "$meta")"    "has_changes flag"
  assert_eq 1     "$(jq -r '.summary.create' "$meta")" "create count in summary"
  assert_eq 1     "$(jq -r '.summary.total' "$meta")"  "total in summary"
  assert_eq mod   "$(jq -r '.name' "$meta")"           "module name"
  assert_contains "$(jq -r '.argv' "$meta")" "plan.sh --no-apply mod" "options executed are recorded"
  assert_contains "$(jq -r '.created_at' "$meta")" "T" "created_at timestamp present"
  case "$(jq -r '.created_epoch' "$meta")" in
    ''|*[!0-9]*) fail "created_epoch not numeric" ;;
    *) pass ;;
  esac
}

test_plan_prompt_defaults_to_not_applying() {
  make_aws_stub ok
  make_tfdata_module mod
  run_plan mod # no --no-apply: prompts, and non-tty stdin answers "no"
  assert_rc 0 "$RC"
  assert_contains "$OUT" "not applying" "declined apply reported"
  assert_no_file mod/terraform.tfstate "nothing was applied"
}

test_plan_skip_fresh_reuses_recent_plan() {
  make_aws_stub ok
  make_tfdata_module mod
  run_plan --no-apply mod
  run_plan --no-apply --skip-fresh 24 mod
  assert_rc 0 "$RC"
  assert_contains "$OUT" "skipping mod" "fresh plan skipped"
  assert_eq 1 "$(ls mod/.terraform/tfplans/*.tfplan | wc -l | tr -d ' ')" "no second plan written"
}

test_plan_no_changes_run() {
  make_aws_stub ok
  make_tfdata_module mod
  run_plan --no-apply mod
  ( cd mod && PATH="$SANDBOX/stub:$PATH" terraform apply -input=false \
      "$(ls .terraform/tfplans/*.tfplan)" ) > /dev/null 2>&1
  run_plan --no-apply mod
  assert_rc 0 "$RC"
  assert_contains "$OUT" "No changes." "no-changes summary"
  assert_eq 0 "$(jq -r '.exit_code' mod/.terraform/tfplans/latest.json)" "exit code 0 recorded"
  assert_eq false "$(jq -r '.has_changes' mod/.terraform/tfplans/latest.json)" "has_changes false"
}

test_plan_flag_validation() {
  make_aws_stub ok
  run_plan --bogus
  assert_rc 2 "$RC" "unknown flag rejected"
  run_plan --skip-fresh nope
  assert_rc 2 "$RC" "non-numeric --skip-fresh rejected"
}

test_plan_missing_dir_fails() {
  make_aws_stub ok
  run_plan --no-apply does-not-exist
  assert_rc 1 "$RC"
  assert_contains "$OUT" "no such directory"
}

run_test test_plan_produces_versioned_artifacts
run_test test_plan_run_metadata_contents
run_test test_plan_prompt_defaults_to_not_applying
run_test test_plan_skip_fresh_reuses_recent_plan
run_test test_plan_no_changes_run
run_test test_plan_flag_validation
run_test test_plan_missing_dir_fails
finish
