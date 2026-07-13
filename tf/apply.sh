#!/usr/bin/env bash
# apply.sh — apply the latest saved plan in one or more root modules.
#
# Reads .terraform/tfplans/latest.json (written by plan.sh), shows the same
# quick summary plan.sh printed, asks y/N, then applies that exact .tfplan
# file — it never re-plans. The apply output is teed to a versioned
# <name>.<ts>.apply.<ts>.log and the result is recorded back into the run
# metadata (applied_at / apply_exit / apply_log).
#
# Usage:
#   ./apply.sh [options] [dir ...]
#     --all         discover every root module under the cwd (backend "s3")
#     -y, --yes     apply without prompting
#     --plan FILE   apply a specific saved .tfplan (its sibling .run.json must exist)
#     (no dir args: the current directory)
#
# Examples:
#   ./apply.sh                          # apply the latest plan here, after a y/N prompt
#   ./apply.sh customers/acme -y        # apply acme's latest plan, no prompt
#   ./apply.sh --plan .terraform/tfplans/acme.20260712T093000.tfplan
set -o pipefail
# abspath <path> — follow symlinks to the real file (portable readlink -f), so
# this script can be symlinked onto PATH (e.g. tools/bin/) and still find
# lib/common.sh next to the real file. Must live here, before the lib exists.
abspath() {
  local p="$1" dir
  while [ -L "$p" ]; do
    dir="$(cd -P "$(dirname "$p")" && pwd)"
    p="$(readlink "$p")"
    case "$p" in /*) ;; *) p="${dir}/${p}" ;; esac
  done
  dir="$(cd -P "$(dirname "$p")" && pwd)"
  printf '%s/%s\n' "$dir" "$(basename "$p")"
}
SCRIPT_DIR="$(dirname "$(abspath "${BASH_SOURCE[0]}")")"
. "${SCRIPT_DIR}/lib/common.sh"

usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ALL=false
AUTO_YES=false
PLAN_FILE=""
DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=true ;;
    -y|--yes) AUTO_YES=true ;;
    --plan) PLAN_FILE="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) err "unknown option: $1"; usage; exit 2 ;;
    *) DIRS+=("$1") ;;
  esac
  shift
done

if [ -n "$PLAN_FILE" ]; then
  [ -f "$PLAN_FILE" ] || { err "no such plan file: $PLAN_FILE"; exit 1; }
  meta="${PLAN_FILE%.tfplan}.run.json"
  [ -f "$meta" ] || { err "no run metadata next to the plan: $meta (was it made by plan.sh?)"; exit 1; }
  apply_run "$meta"
  exit $?
fi

collect_module_dirs
rc=0
for d in "${MODULE_DIRS[@]}"; do
  meta="${d}/.terraform/tfplans/latest.json"
  if [ ! -f "$meta" ]; then
    warn "no saved plan in ${d} — run plan.sh first"
    rc=1
    continue
  fi
  apply_run "$meta" || rc=1
done
exit "$rc"
