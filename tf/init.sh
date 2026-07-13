#!/usr/bin/env bash
# init.sh — self-correcting `terraform init` across one or more root modules.
#
# Self-corrects two common failures:
#   * expired AWS credentials — verifies with `aws sts get-caller-identity`
#     first, and if init still hits an auth error, pauses so you can refresh
#     credentials in another terminal, then retries
#   * changed backend config  — reruns once with `terraform init -reconfigure`
#     when terraform's error recommends it
#
# Usage:
#   ./init.sh [options] [dir ...] [-- <extra terraform init args>]
#     --all         discover every root module under the cwd (*.tf with `backend "s3"`)
#     (no dir args: the current directory)
#
# Examples:
#   ./init.sh                          # init the root module you're standing in
#   ./init.sh customers/acme           # init one specific module
#   ./init.sh --all                    # init every discovered root module
#   ./init.sh -- -upgrade              # pass -upgrade through to terraform init
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

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ALL=false
DIRS=()
TF_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=true ;;
    -h|--help) usage; exit 0 ;;
    --) shift; TF_ARGS=("$@"); break ;;
    -*) err "unknown option: $1"; usage; exit 2 ;;
    *) DIRS+=("$1") ;;
  esac
  shift
done

collect_module_dirs
ensure_aws_auth || exit 1

rc=0
for d in "${MODULE_DIRS[@]}"; do
  banner "terraform init — ${d}"
  init_module "$d" "${TF_ARGS[@]}" || rc=1
done
exit "$rc"
