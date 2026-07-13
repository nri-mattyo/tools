#!/usr/bin/env bash
# Unit tests for the failure-output classifiers in lib/common.sh that drive
# the self-correction behavior (expired-creds retry, -reconfigure rerun).
. "$(cd "$(dirname "$0")" && pwd)/helpers.sh"
. "$TF_DIR/lib/common.sh"

# expect_match <0|1> <classifier> <text> — 0: must match, 1: must not
expect_match() {
  if [ "$1" -eq 0 ]; then
    if "$2" "$3"; then pass; else fail "$2 should match: $3"; fi
  else
    if "$2" "$3"; then fail "$2 should NOT match: $3"; else pass; fi
  fi
}

test_auth_error_matches() {
  expect_match 0 looks_like_auth_error 'Error: error configuring S3 Backend: ExpiredToken: The security token included in the request is expired'
  expect_match 0 looks_like_auth_error 'Error: No valid credential sources found'
  expect_match 0 looks_like_auth_error 'failed to refresh cached credentials, the SSO session has expired or is invalid'
  expect_match 0 looks_like_auth_error 'InvalidClientTokenId: The security token included in the request is invalid'
  expect_match 0 looks_like_auth_error 'operation error STS: AssumeRole, https response error ... api error ExpiredToken'
}

test_auth_error_ignores_unrelated() {
  expect_match 1 looks_like_auth_error 'Error: Invalid resource type "aws_foo" on main.tf line 3'
  expect_match 1 looks_like_auth_error 'Error: creating S3 Bucket: BucketAlreadyExists'
  expect_match 1 looks_like_auth_error 'Terraform has been successfully initialized!'
}

test_backend_change_matches() {
  expect_match 0 looks_like_backend_change 'Error: Backend configuration changed
A change in the backend configuration has been detected, which may require migrating existing state. Use "terraform init -reconfigure" ...'
  expect_match 0 looks_like_backend_change 'Error: Backend initialization required, please run "terraform init"'
}

test_backend_change_ignores_unrelated() {
  expect_match 1 looks_like_backend_change 'Error: Unsupported argument on main.tf line 3'
  expect_match 1 looks_like_backend_change 'Error: error configuring S3 Backend: ExpiredToken: expired'
}

run_test test_auth_error_matches
run_test test_auth_error_ignores_unrelated
run_test test_backend_change_matches
run_test test_backend_change_ignores_unrelated
finish
