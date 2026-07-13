#!/usr/bin/env bash
# Regression tests for the plan-report*.sh scripts. The key case: a no-changes
# plan, where `terraform show -json` omits the resource_changes key entirely —
# an unguarded .resource_changes[] makes jq abort with "Cannot iterate over
# null", killing a whole multi-customer report run.
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

REPORTS="plan-report.sh plan-report-md.sh plan-report-aligned.sh plan-report-tree.sh plan-report-alarms.sh"

test_reports_survive_no_changes_plan() {
  local r out rc
  for r in $REPORTS; do
    out="$("$TF_DIR/$r" "$FIXTURES/no-changes-plan.json" 2>&1)"; rc=$?
    assert_rc 0 "$rc" "$r on a no-changes plan"
    assert_not_contains "$out" "Cannot iterate" "$r must not abort on missing resource_changes"
  done
}

test_reports_survive_mixed_input() {
  # A no-changes plan mixed into a glob must not poison the changed ones.
  local r out rc
  for r in $REPORTS; do
    out="$("$TF_DIR/$r" "$FIXTURES/no-changes-plan.json" "$FIXTURES/fake-plan.json" 2>&1)"; rc=$?
    assert_rc 0 "$rc" "$r on mixed no-changes + changes input"
    assert_not_contains "$out" "Cannot iterate" "$r must not abort mid-glob"
  done
}

test_md_report_renders_changes() {
  local out
  out="$("$TF_DIR/plan-report-md.sh" "$FIXTURES/fake-plan.json" 2>&1)"
  assert_contains "$out" "change(s)" "renders the changes header"
  assert_contains "$out" "aws_s3_bucket.new" "lists a changed resource"
  assert_contains "$out" "delete — <code>aws_instance.old</code>" "lists a deleted resource"
}

test_md_report_renders_imports_removed_and_moves() {
  local out
  out="$("$TF_DIR/plan-report-md.sh" "$FIXTURES/fake-plan.json" 2>&1)"
  assert_contains "$out" "1 import(s), 1 removed, 1 move(s)" "header counts all buckets"
  assert_contains "$out" "1 imported (adopted into state)" "imports section"
  assert_contains "$out" "aws_cloudwatch_metric_alarm.cpu  (id: cpu-alarm-1)" "import address + id"
  assert_contains "$out" "1 removed from state (not destroyed)" "removed section"
  assert_contains "$out" "aws_ssm_parameter.p" "removed address"
  assert_contains "$out" "1 moved (address change only)" "moves section"
  assert_contains "$out" "aws_sqs_queue.old_q" "move lists the old address"
  assert_contains "$out" "=> aws_sqs_queue.q" "move lists the new address"
}

test_md_report_includes_moves_only_plans() {
  # A plan with ONLY a move (no changes) must not be filtered out of the report.
  jq '{format_version, resource_changes: [.resource_changes[] | select(.previous_address != null)]}' \
    "$FIXTURES/fake-plan.json" > moves-only.json
  local out
  out="$("$TF_DIR/plan-report-md.sh" moves-only.json 2>&1)"
  assert_contains "$out" "1 move(s)" "moves-only plan still reported"
  assert_not_contains "$out" "change(s)" "no empty changes header"
}

test_baseline_report_renders_changes() {
  local out
  out="$("$TF_DIR/plan-report.sh" "$FIXTURES/fake-plan.json" 2>&1)"
  assert_contains "$out" "Changes (" "renders the changes section"
  assert_contains "$out" "aws_s3_bucket.new" "lists a changed resource"
}

run_test test_reports_survive_no_changes_plan
run_test test_reports_survive_mixed_input
run_test test_md_report_renders_changes
run_test test_md_report_renders_imports_removed_and_moves
run_test test_md_report_includes_moves_only_plans
run_test test_baseline_report_renders_changes
finish
