#!/usr/bin/env bash
# plan.sh — terraform plan wrapper with versioned artifacts and a quick summary.
#
# For each targeted root module it:
#   1. runs the self-correcting init (see init.sh / lib/common.sh)
#   2. runs `terraform plan -out` into .terraform/tfplans/<name>.<ts>.tfplan,
#      teeing stdout+stderr to <name>.<ts>.tfplan.log and exporting the JSON
#      to <name>.<ts>.tfplan.json
#   3. writes <name>.<ts>.run.json (argv, aws profile, exit code, per-action
#      counts) and refreshes .terraform/tfplans/latest.json plus the
#      .terraform/latest.tfplan.json copy the plan-report scripts consume
#   4. prints a quick per-action summary parsed from the plan JSON
#   5. offers to apply the saved plan (y/N), or applies it automatically with
#      --auto-apply, or stays hands-off with --no-apply
#
# Usage:
#   ./plan.sh [options] [dir ...] [-- <extra terraform plan args>]
#     --all              discover every root module under the cwd (backend "s3")
#     --skip-fresh N     skip a module whose latest plan is newer than N hours
#     -y, --auto-apply   apply each plan that has changes, without prompting
#     --no-apply         never offer to apply (plan/report only)
#     (no dir args: the current directory)
#
# Examples:
#   ./plan.sh                                # plan the module you're standing in, then ask
#   ./plan.sh customers/acme -- -var-file=x.tfvars
#   ./plan.sh --all --no-apply --skip-fresh 24   # the old sweep behavior
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

RUN_ARGV="plan.sh $*"
ALL=false
APPLY_MODE=prompt   # prompt | auto | never
SKIP_FRESH_HOURS=0
DIRS=()
TF_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=true ;;
    --skip-fresh)
      SKIP_FRESH_HOURS="${2:-}"; shift
      case "$SKIP_FRESH_HOURS" in (''|*[!0-9]*) err "--skip-fresh needs a number of hours"; exit 2 ;; esac ;;
    -y|--auto-apply) APPLY_MODE=auto ;;
    --no-apply) APPLY_MODE=never ;;
    -h|--help) usage; exit 0 ;;
    --) shift; TF_ARGS=("$@"); break ;;
    -*) err "unknown option: $1"; usage; exit 2 ;;
    *) DIRS+=("$1") ;;
  esac
  shift
done

# plan_module <dir> — appends the produced plan JSON to PLANNED_JSONS.
plan_module() {
  local dir="$1" d_abs name ts base rc attempt counts
  d_abs="$(cd "$dir" 2>/dev/null && pwd)" || { err "no such directory: $dir"; return 1; }
  name="$(basename "$d_abs")"
  banner "tf plan — ${name}"

  if [ "$SKIP_FRESH_HOURS" -gt 0 ] && [ -f "${d_abs}/.terraform/tfplans/latest.json" ]; then
    local prev_epoch age
    prev_epoch="$(jq -r '.created_epoch // 0' "${d_abs}/.terraform/tfplans/latest.json")"
    age=$(( $(date +%s) - prev_epoch ))
    if [ "$age" -lt $(( SKIP_FRESH_HOURS * 3600 )) ]; then
      info "skipping ${name}: latest plan is $(fmt_age "$age") old (< ${SKIP_FRESH_HOURS}h)"
      local prev_json
      prev_json="$(jq -r '.json_file // empty' "${d_abs}/.terraform/tfplans/latest.json")"
      [ -n "$prev_json" ] && [ -f "$prev_json" ] && PLANNED_JSONS+=("$prev_json")
      return 0
    fi
  fi

  init_module "$d_abs" || return 1

  mkdir -p "${d_abs}/.terraform/tfplans"
  ts="$(date +"%Y%m%dT%H%M%S")"
  base="${d_abs}/.terraform/tfplans/${name}.${ts}"

  # -detailed-exitcode: 0 = no changes, 1 = error, 2 = changes present.
  attempt=0
  while :; do
    attempt=$((attempt + 1))
    ( cd "$d_abs" && terraform plan -input=false -detailed-exitcode -no-color \
        -out "${base}.tfplan" "${TF_ARGS[@]}" ) 2>&1 | tee "${base}.tfplan.log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 1 ] && [ "$attempt" -lt 3 ] && looks_like_auth_error "$(cat "${base}.tfplan.log")"; then
      warn "terraform plan failed — AWS credentials look expired"
      ensure_aws_auth || break
      continue
    fi
    break
  done

  if [ "$rc" -eq 1 ]; then
    write_run_meta "$d_abs" "$name" "$ts" "$base" 1 'null'
    err "terraform plan failed in ${name} (log: ${base}.tfplan.log)"
    return 1
  fi

  ( cd "$d_abs" && terraform show -json "${base}.tfplan" ) > "${base}.tfplan.json" \
    || { err "terraform show -json failed in ${name}"; return 1; }
  # back-compat: the plan-report*.sh scripts read this copy
  cp "${base}.tfplan.json" "${d_abs}/.terraform/latest.tfplan.json"

  counts="$(plan_counts "${base}.tfplan.json")"
  write_run_meta "$d_abs" "$name" "$ts" "$base" "$rc" "$counts"

  echo
  plan_quick_summary "${base}.tfplan.json"
  echo
  info "artifacts: ${base}.{tfplan,tfplan.log,tfplan.json,run.json}"
  PLANNED_JSONS+=("${base}.tfplan.json")

  if [ "$rc" -eq 2 ]; then
    case "$APPLY_MODE" in
      never) info "not applying (--no-apply); apply later with: ${SCRIPT_DIR}/apply.sh ${dir}" ;;
      auto)  apply_run "${base}.run.json" false true ;;
      *)
        if confirm "Apply these changes to ${name} now?"; then
          apply_run "${base}.run.json" false true
        else
          info "not applying ${name}; apply later with: ${SCRIPT_DIR}/apply.sh ${dir}"
        fi ;;
    esac
  fi
}

collect_module_dirs
ensure_aws_auth || exit 1

PLANNED_JSONS=()
overall_rc=0
for d in "${MODULE_DIRS[@]}"; do
  plan_module "$d" || overall_rc=1
done

# Combined report when sweeping several modules, as the old plan.sh did.
if [ ${#PLANNED_JSONS[@]} -gt 1 ] && [ -x "${SCRIPT_DIR}/plan-report.sh" ]; then
  "${SCRIPT_DIR}/plan-report.sh" "${PLANNED_JSONS[@]}"
fi
exit "$overall_rc"
