#!/usr/bin/env bash
# Unit tests for the plan-JSON parsing helpers in lib/common.sh:
# plan_counts, plan_quick_summary, fmt_age. Pure jq/bash — no terraform.
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
. "$TF_DIR/lib/common.sh"

test_counts_cover_every_action() {
  local counts
  counts="$(plan_counts "$FIXTURES/fake-plan.json")"
  assert_eq 1 "$(jq -r '.create'  <<<"$counts")" "create count"
  assert_eq 1 "$(jq -r '.update'  <<<"$counts")" "update count"
  assert_eq 1 "$(jq -r '.destroy' <<<"$counts")" "destroy count"
  assert_eq 1 "$(jq -r '.replace' <<<"$counts")" "replace count"
  assert_eq 1 "$(jq -r '.forget'  <<<"$counts")" "forget count"
  assert_eq 1 "$(jq -r '.import'  <<<"$counts")" "import count"
  assert_eq 1 "$(jq -r '.move'    <<<"$counts")" "move count"
  assert_eq 5 "$(jq -r '.total'   <<<"$counts")" "total excludes imports/moves"
}

test_counts_empty_plan() {
  local counts
  counts="$(plan_counts "$FIXTURES/empty-plan.json")"
  assert_eq 0 "$(jq -r '.total' <<<"$counts")" "empty plan total"
}

test_summary_header_line() {
  local out
  out="$(plan_quick_summary "$FIXTURES/fake-plan.json")"
  assert_contains "$out" "Plan: 1 to create, 1 to update, 1 to destroy, 1 to replace, 1 to import, 1 to forget" "header counts"
  assert_contains "$out" "(+1 moved)" "moved suffix"
}

test_summary_resource_lines() {
  local out
  out="$(plan_quick_summary "$FIXTURES/fake-plan.json")"
  assert_contains "$out" "[create] aws_s3_bucket.new"
  assert_contains "$out" "[update] aws_iam_role.web"
  assert_contains "$out" "[delete] aws_instance.old"
  assert_contains "$out" "[delete/create] aws_ecs_service.app"
  assert_contains "$out" "[forget] aws_ssm_parameter.p"
  assert_contains "$out" '[import] aws_cloudwatch_metric_alarm.cpu  (id: cpu-alarm-1)'
}

test_summary_hides_noise() {
  local out
  out="$(plan_quick_summary "$FIXTURES/fake-plan.json")"
  assert_not_contains "$out" "no-op" "no-op resources hidden"
  assert_not_contains "$out" "data.aws_caller_identity" "data reads hidden"
  assert_not_contains "$out" "aws_route53_record.same" "unchanged resources hidden"
}

test_summary_no_changes() {
  assert_eq "No changes." "$(plan_quick_summary "$FIXTURES/empty-plan.json")" "empty plan message"
}

test_fmt_age() {
  assert_eq "12m"    "$(fmt_age 720)"
  assert_eq "3h 24m" "$(fmt_age 12240)"
  assert_eq "2d 3h"  "$(fmt_age 183600)"
}

run_test test_counts_cover_every_action
run_test test_counts_empty_plan
run_test test_summary_header_line
run_test test_summary_resource_lines
run_test test_summary_hides_noise
run_test test_summary_no_changes
run_test test_fmt_age
finish
