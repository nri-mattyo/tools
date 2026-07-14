#!/usr/bin/env bash
# helpers.sh — sourced by every test_*.sh. Provides asserts, a per-test tmp
# sandbox, and fake `aws` / `terraform` stubs so failure paths are exercised
# deterministically. Zero dependencies beyond bash + jq (+ a real terraform
# binary for the integration files). bash 3.2 compatible.
#
# Test file shape:
#   . "$(dirname "$0")/helpers.sh"
#   test_something() { ...asserts... }
#   run_test test_something
#   finish
#
# Each run_test executes the function with cwd set to a fresh sandbox dir.
# Asserts never exit the shell; finish prints the tally and sets the file's
# exit code. Stdin is non-tty under the runner, so `confirm` answers "no" and
# ensure_aws_auth refuses to wait — interactive prompt paths are exercised via
# their documented non-interactive fallbacks.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$TESTS_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

export NO_COLOR=1           # keep assertions free of ANSI escapes
export CHECKPOINT_DISABLE=1 # no terraform version-check network calls
export TF_IN_AUTOMATION=1

_pass=0
_fail=0
_current="(setup)"

SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tftests.XXXXXX")"
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

pass() { _pass=$((_pass + 1)); }
fail() { _fail=$((_fail + 1)); echo "    FAIL [${_current}] $*" >&2; }

assert_rc()  { if [ "$1" -eq "$2" ]; then pass; else fail "${3:-rc}: expected exit $1, got $2"; fi; }
assert_eq()  { if [ "$1" = "$2" ];  then pass; else fail "${3:-eq}: expected '$1', got '$2'"; fi; }
assert_contains() {
  case "$1" in
    *"$2"*) pass ;;
    *) fail "${3:-contains}: '$2' not in output:"
       printf '%s\n' "$1" | sed 's/^/      | /' | head -30 >&2 ;;
  esac
}
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "${3:-not_contains}: unexpected '$2' in output" ;;
    *) pass ;;
  esac
}
assert_file()    { if [ -f "$1" ]; then pass; else fail "${2:-file}: missing $1"; fi; }
assert_no_file() { if [ -f "$1" ]; then fail "${2:-no_file}: unexpected $1"; else pass; fi; }

run_test() {
  _current="$1"
  SANDBOX="${SANDBOX_ROOT}/$1"
  mkdir -p "$SANDBOX"
  cd "$SANDBOX" || { fail "could not cd into sandbox"; return; }
  "$1"
  cd "$SANDBOX_ROOT" || exit 1
}

finish() {
  echo "  ${_pass} passed, ${_fail} failed"
  [ "$_fail" -eq 0 ]
}

# ---- stubs -------------------------------------------------------------------
# Both stubs land in $SANDBOX/stub; tests activate them by prepending that dir:
#   PATH="$SANDBOX/stub:$PATH" "$TF_DIR/plan.sh" ...

# make_aws_stub [ok|fail] — fake `aws` CLI. ok: sts succeeds with a canned
# identity; fail: every call errors like an expired token.
make_aws_stub() {
  mkdir -p "$SANDBOX/stub"
  case "${1:-ok}" in
    fail)
      cat > "$SANDBOX/stub/aws" <<'EOF'
#!/usr/bin/env bash
echo "An error occurred (ExpiredToken) when calling the GetCallerIdentity operation: The security token included in the request is expired" >&2
exit 255
EOF
      ;;
    *)
      cat > "$SANDBOX/stub/aws" <<'EOF'
#!/usr/bin/env bash
echo '{"UserId":"TEST","Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/test/test"}'
EOF
      ;;
  esac
  chmod +x "$SANDBOX/stub/aws"
}

# make_tf_stub <ok|auth-once|backend-change|hard-fail> [plan-mode] — fake
# `terraform` whose `init` behavior is driven by a mode file (so a mode can
# flip itself after one failure). Every invocation is appended to
# $SANDBOX/stub/tf-calls.log.
#   init modes:
#     ok             init succeeds
#     auth-once      first init fails with an ExpiredToken error, then succeeds
#     backend-change init fails asking for -reconfigure until it's passed
#     hard-fail      init always fails with a non-recoverable config error
#   plan modes (default ok):
#     ok             plan writes the -out file, exits 2 (changes present)
#     sleep          same, after sleeping 2s; start/end epochs per module are
#                    recorded in plan-times.log (for concurrency assertions)
#     auth-fail      plan fails with an ExpiredToken error
#   `show -json` emits a canned plan with one of each: create, import, forget,
#   move — so FULL-count rendering (zeros included) is exercised.
make_tf_stub() {
  mkdir -p "$SANDBOX/stub"
  printf '%s\n' "${1:-ok}" > "$SANDBOX/stub/mode"
  printf '%s\n' "${2:-ok}" > "$SANDBOX/stub/plan-mode"
  cat > "$SANDBOX/stub/canned-plan.json" <<'EOF'
{
  "format_version": "1.2",
  "resource_changes": [
    {"address": "aws_s3_bucket.new", "change": {"actions": ["create"], "importing": null}},
    {"address": "aws_cloudwatch_metric_alarm.cpu", "change": {"actions": ["no-op"], "importing": {"id": "cpu-alarm-1"}}},
    {"address": "aws_ssm_parameter.p", "change": {"actions": ["forget"], "importing": null}},
    {"address": "aws_sqs_queue.q", "previous_address": "aws_sqs_queue.old_q", "change": {"actions": ["no-op"], "importing": null}}
  ]
}
EOF
  cat > "$SANDBOX/stub/terraform" <<'EOF'
#!/usr/bin/env bash
STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "$*" >> "$STATE_DIR/tf-calls.log"
case "$1" in
  version)
    echo '{"terraform_version":"0.0.0-stub"}'
    ;;
  init)
    mode="$(cat "$STATE_DIR/mode")"
    case "$mode" in
      ok)
        echo "Terraform has been successfully initialized!"
        ;;
      auth-once)
        echo ok > "$STATE_DIR/mode"
        echo "Error: error configuring S3 Backend: ExpiredToken: The security token included in the request is expired"
        exit 1
        ;;
      backend-change)
        case " $* " in
          *" -reconfigure "*)
            echo "Terraform has been successfully initialized!"
            ;;
          *)
            echo "Error: Backend configuration changed"
            echo 'A change in the backend configuration has been detected. Use "terraform init -reconfigure" to keep the current configuration.'
            exit 1
            ;;
        esac
        ;;
      hard-fail)
        echo "Error: Unsupported argument"
        exit 1
        ;;
    esac
    ;;
  plan)
    pmode="$(cat "$STATE_DIR/plan-mode")"
    module="$(basename "$PWD")"
    case "$pmode" in
      auth-fail)
        echo "Error: error configuring S3 Backend: ExpiredToken: The security token included in the request is expired"
        exit 1
        ;;
      sleep)
        echo "$module start $(date +%s)" >> "$STATE_DIR/plan-times.log"
        sleep 2
        echo "$module end $(date +%s)" >> "$STATE_DIR/plan-times.log"
        ;;
    esac
    # honor -out <file> so the wrapper's artifact checks hold
    prev=""
    for a in "$@"; do
      [ "$prev" = "-out" ] && echo "stub-plan" > "$a"
      prev="$a"
    done
    echo "Plan: 1 to add, 0 to change, 0 to destroy."
    exit 2
    ;;
  show)
    cat "$STATE_DIR/canned-plan.json"
    ;;
esac
exit 0
EOF
  chmod +x "$SANDBOX/stub/terraform"
}

# make_tfdata_module <dir> — a real root module using only the builtin
# terraform_data resource: local state, no provider downloads, no network.
make_tfdata_module() {
  mkdir -p "$1"
  cat > "$1/main.tf" <<'EOF'
resource "terraform_data" "hello" {
  input = "hello-world"
}
EOF
}
