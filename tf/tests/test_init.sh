#!/usr/bin/env bash
# Self-correction tests for init.sh, driven by the fake `terraform` stub so
# every failure mode is deterministic (no real backends, no network, no creds).
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"

# run_init [args...] — invoke init.sh with the sandbox stubs first on PATH,
# stdin closed (non-interactive). Sets OUT and RC.
run_init() {
  OUT="$(PATH="$SANDBOX/stub:$PATH" "$TF_DIR/init.sh" "$@" < /dev/null 2>&1)"
  RC=$?
}

init_calls() { grep -c '^init' "$SANDBOX/stub/tf-calls.log"; }

test_init_success() {
  make_aws_stub ok
  make_tf_stub ok
  mkdir -p mod
  run_init mod
  assert_rc 0 "$RC"
  assert_contains "$OUT" "successfully initialized"
  assert_eq 1 "$(init_calls)" "exactly one init call"
}

test_init_retries_after_expired_credentials() {
  make_aws_stub ok       # sts works, so the retry proceeds without prompting
  make_tf_stub auth-once # first init fails with ExpiredToken, then succeeds
  mkdir -p mod
  run_init mod
  assert_rc 0 "$RC" "recovers without user input"
  assert_contains "$OUT" "credentials look expired" "explains the retry"
  assert_contains "$OUT" "successfully initialized"
  assert_eq 2 "$(init_calls)" "failed init + successful retry"
}

test_init_reconfigures_on_backend_change() {
  make_aws_stub ok
  make_tf_stub backend-change
  mkdir -p mod
  run_init mod
  assert_rc 0 "$RC"
  assert_contains "$OUT" "rerunning with 'terraform init -reconfigure'" "announces the self-correction"
  assert_eq 1 "$(grep -c '^init .*-reconfigure' "$SANDBOX/stub/tf-calls.log")" "reran with -reconfigure once"
  assert_contains "$OUT" "migrate-state" "mentions the migrate-state alternative"
}

test_init_hard_failure_is_not_retried() {
  make_aws_stub ok
  make_tf_stub hard-fail
  mkdir -p mod
  run_init mod
  assert_rc 1 "$RC" "unrecoverable error bubbles up"
  assert_eq 1 "$(init_calls)" "no blind retries on config errors"
}

test_init_noninteractive_bad_credentials_abort() {
  make_aws_stub fail # sts itself fails and stdin is closed -> cannot wait
  make_tf_stub ok
  mkdir -p mod
  run_init mod
  assert_rc 1 "$RC"
  assert_contains "$OUT" "non-interactive" "explains why it cannot wait for a refresh"
}

test_init_passthrough_args() {
  make_aws_stub ok
  make_tf_stub ok
  mkdir -p mod
  run_init mod -- -upgrade
  assert_rc 0 "$RC"
  assert_eq 1 "$(grep -c '^init .*-upgrade' "$SANDBOX/stub/tf-calls.log")" "-upgrade passed through"
}

test_init_unknown_flag_errors() {
  make_aws_stub ok
  make_tf_stub ok
  run_init --bogus
  assert_rc 2 "$RC"
  assert_contains "$OUT" "unknown option"
}

run_test test_init_success
run_test test_init_retries_after_expired_credentials
run_test test_init_reconfigures_on_backend_change
run_test test_init_hard_failure_is_not_retried
run_test test_init_noninteractive_bad_credentials_abort
run_test test_init_passthrough_args
run_test test_init_unknown_flag_errors
finish
