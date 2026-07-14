#!/usr/bin/env bash
# lib/common.sh — shared helpers for the tf wrapper commands (init.sh, plan.sh,
# apply.sh). Sourced, not executed. bash 3.2 compatible (macOS default).
#
# Callers set these globals before using the helpers:
#   ALL=true|false   DIRS=(...)        — consumed by collect_module_dirs
#   AUTO_YES=true    NO_INPUT=true     — consumed by confirm
#   RUN_ARGV="..."                     — recorded into run.json by write_run_meta

TF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_TOOLS_DIR="$(dirname "$TF_LIB_DIR")"

export AWS_DEFAULT_PROFILE="${AWS_DEFAULT_PROFILE:-nri-customer}"

for _cmd in terraform jq aws; do
  command -v "$_cmd" >/dev/null 2>&1 || { echo "error: required command not found: $_cmd" >&2; exit 1; }
done

# ---- output -----------------------------------------------------------------
# Colorize only on a terminal; honor the NO_COLOR convention (no-color.org).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then TF_COLOR=true; else TF_COLOR=false; fi

paint() { # paint <sgr-code> <text...>
  local code="$1"; shift
  if $TF_COLOR; then printf '\033[%sm%s\033[0m' "$code" "$*"; else printf '%s' "$*"; fi
}
info()   { printf '%s %s\n' "$(paint 36 '==>')" "$*"; }
warn()   { printf '%s %s\n' "$(paint 33 'warning:')" "$*" >&2; }
err()    { printf '%s %s\n' "$(paint 31 'error:')" "$*" >&2; }
hr()     { printf '%*s\n' 50 '' | tr ' ' '*'; }
banner() { hr; echo "*** $*"; hr; }

fmt_age() { # fmt_age <seconds> -> "2d 3h" / "3h 24m" / "12m" / "42s"
  local s="$1"
  if   [ "$s" -ge 86400 ]; then echo "$(( s / 86400 ))d $(( (s % 86400) / 3600 ))h"
  elif [ "$s" -ge 3600 ];  then echo "$(( s / 3600 ))h $(( (s % 3600) / 60 ))m"
  elif [ "$s" -ge 60 ];    then echo "$(( s / 60 ))m"
  else                          echo "${s}s"
  fi
}

# ---- prompts ------------------------------------------------------------
# confirm "<question>" — 0 on yes. AUTO_YES=true answers yes without asking;
# NO_INPUT=true or a non-interactive stdin answers no without asking.
confirm() {
  local q="$1" ans
  if [ "${AUTO_YES:-false}" = true ]; then
    info "$q — auto-approved"
    return 0
  fi
  if [ "${NO_INPUT:-false}" = true ] || [ ! -t 0 ]; then
    return 1
  fi
  while :; do
    printf '%s [y/N] ' "$q"
    read -r ans || return 1
    case "$ans" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No|'') return 1 ;;
      *) echo "please answer y or n" ;;
    esac
  done
}

# ---- AWS credentials ----------------------------------------------------
# ensure_aws_auth — verify the active credentials actually work. On failure,
# pause so the user can refresh them in another terminal, then retry.
ensure_aws_auth() {
  local out ans
  while :; do
    if out="$(aws sts get-caller-identity --output json 2>&1)"; then
      info "AWS credentials OK: $(jq -r '.Arn' <<<"$out" 2>/dev/null)"
      return 0
    fi
    err "AWS credential check failed (profile: ${AWS_PROFILE:-$AWS_DEFAULT_PROFILE}):"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    if [ ! -t 0 ]; then
      err "non-interactive session — cannot wait for refreshed credentials"
      return 1
    fi
    printf 'Refresh your AWS credentials in another terminal, then press Enter to retry (q to abort): '
    read -r ans || return 1
    case "$ans" in q|Q) return 1 ;; esac
  done
}

# Classify terraform failure output so init/plan can self-correct.
looks_like_auth_error() {
  grep -qiE 'ExpiredToken|token .*(is |has )?expired|InvalidClientTokenId|no valid credential|failed to refresh cached|SSO session|credentials.* expired|InvalidGrantException|AuthFailure' <<<"$1"
}
looks_like_backend_change() {
  grep -qiE 'Backend configuration changed|Backend initialization required|terraform init -reconfigure' <<<"$1"
}

# ---- root-module discovery -----------------------------------------------
# Every directory under the cwd containing a *.tf with `backend "s3"` — same
# discovery rule the original plan.sh used.
discover_root_modules() {
  { if command -v rg >/dev/null 2>&1; then
      rg -l 'backend "s3"' -g '*.tf' . 2>/dev/null
    else
      grep -rl --include='*.tf' 'backend "s3"' . 2>/dev/null
    fi
  } | while IFS= read -r f; do dirname "$f"; done | sort -u
}

# collect_module_dirs — resolve targets into MODULE_DIRS[] from the caller's
# ALL / DIRS globals. Default: the current directory.
collect_module_dirs() {
  MODULE_DIRS=()
  if [ "${ALL:-false}" = true ]; then
    local d
    while IFS= read -r d; do [ -n "$d" ] && MODULE_DIRS+=("$d"); done < <(discover_root_modules)
    if [ ${#MODULE_DIRS[@]} -eq 0 ]; then
      err "no root modules (backend \"s3\") found under $(pwd)"
      exit 1
    fi
    info "discovered ${#MODULE_DIRS[@]} root module(s)"
  elif [ ${#DIRS[@]} -gt 0 ]; then
    MODULE_DIRS=("${DIRS[@]}")
  else
    MODULE_DIRS=(".")
  fi
}

# ---- terraform init with self-correction ---------------------------------
# init_module <dir> [extra terraform init args...]
#   * expired AWS credentials -> pause for a refresh (ensure_aws_auth), retry
#   * changed backend config  -> rerun once with -reconfigure, as terraform
#     recommends. If you intentionally MOVED state to a new backend, run
#     `terraform init -migrate-state` yourself instead.
init_module() {
  local dir="$1"; shift
  (
    cd "$dir" || exit 1
    local attempt=0 reconfigured=false out rc
    while :; do
      attempt=$((attempt + 1))
      out="$(terraform init -input=false "$@" 2>&1)"; rc=$?
      printf '%s\n' "$out"
      [ "$rc" -eq 0 ] && exit 0
      if [ "$attempt" -ge 4 ]; then
        err "terraform init still failing after ${attempt} attempts in ${dir}"
        exit "$rc"
      fi
      if looks_like_auth_error "$out"; then
        warn "terraform init failed — AWS credentials look expired"
        ensure_aws_auth || exit "$rc"
      elif [ "$reconfigured" = false ] && looks_like_backend_change "$out"; then
        warn "backend configuration changed — rerunning with 'terraform init -reconfigure' (terraform's recommendation)"
        warn "if you actually moved state to a new backend, abort and run 'terraform init -migrate-state' instead"
        set -- -reconfigure "$@"
        reconfigured=true
      else
        exit "$rc"
      fi
    done
  )
}

# ---- plan JSON parsing ----------------------------------------------------
# plan_counts <plan.json> — compact JSON object of per-action counts, stored in
# run.json and used for has-changes checks.
plan_counts() {
  jq -c '
    [.resource_changes[]?] as $all
    | { create:  ($all | map(select(.change.actions == ["create"])) | length),
        update:  ($all | map(select(.change.actions == ["update"])) | length),
        destroy: ($all | map(select(.change.actions == ["delete"])) | length),
        replace: ($all | map(select(.change.actions == ["delete","create"]
                              or .change.actions == ["create","delete"])) | length),
        forget:  ($all | map(select(.change.actions == ["forget"])) | length),
        import:  ($all | map(select(.change.importing != null)) | length),
        move:    ($all | map(select(.previous_address != null)) | length) }
    | . + { total: (.create + .update + .destroy + .replace + .forget) }
  ' "$1"
}

# plan_quick_summary <plan.json> — one "Plan: ..." counts line plus a colored
# line per changed resource (sorted by action, then address).
plan_quick_summary() {
  local color; if $TF_COLOR; then color=true; else color=false; fi
  jq -r --argjson color "$color" '
    def paint($c): if $color then "[\($c)m\(.)[0m" else . end;
    def action_color:
      if   . == ["create"] then "32"
      elif . == ["update"] then "33"
      elif . == ["delete"] then "31"
      elif . == ["forget"] then "36"
      else "35" end;                                  # replace & anything exotic
    [.resource_changes[]?] as $all
    | ($all | map(select(.change.actions[0] != "no-op" and .change.actions[0] != "read"))) as $eff
    | ($all | map(select(.change.importing != null))) as $imports
    | ($all | map(select(.previous_address != null))) as $moves
    | ($eff | map(select(.change.actions == ["create"])) | length) as $create
    | ($eff | map(select(.change.actions == ["update"])) | length) as $update
    | ($eff | map(select(.change.actions == ["delete"])) | length) as $destroy
    | ($eff | map(select(.change.actions == ["delete","create"]
                   or .change.actions == ["create","delete"])) | length) as $replace
    | ($eff | map(select(.change.actions == ["forget"])) | length) as $forget
    | if ($eff | length) == 0 and ($imports | length) == 0 and ($moves | length) == 0 then
        "No changes."
      else
        ( [ $eff[] | . as $rc
            | { sort: "\($rc.change.actions | join("/")) \($rc.address)",
                out:  ("  [\($rc.change.actions | join("/"))] \($rc.address)"
                       | paint($rc.change.actions | action_color)) } ]
          | sort_by(.sort) | map(.out) ) as $lines
        | ( [ $imports[]
              | ("  [import] \(.address)  (id: \(.change.importing.id // "?"))" | paint("34")) ]
            | sort ) as $ilines
        | ( [ "Plan: \($create) to create, \($update) to update, \($destroy) to destroy, \($replace) to replace"
              + (if ($imports | length) > 0 then ", \($imports | length) to import" else "" end)
              + (if $forget > 0 then ", \($forget) to forget (removed from state only)" else "" end)
              + (if ($moves | length) > 0 then "  (+\($moves | length) moved)" else "" end) ]
            + $lines + $ilines )
        | join("\n")
      end
  ' "$1"
}

# fresh_plan_json <abs-dir> — succeeds when the latest plan is newer than
# SKIP_FRESH_HOURS, echoing its json path (if the file still exists) so the
# caller can reuse it in reports. Fails when a new plan is needed.
# SKIP_FRESH_HOURS=0/unset disables freshness skipping.
fresh_plan_json() {
  local dir="$1" latest="$1/.terraform/tfplans/latest.json" prev_epoch age j
  [ "${SKIP_FRESH_HOURS:-0}" -gt 0 ] || return 1
  [ -f "$latest" ] || return 1
  prev_epoch="$(jq -r '.created_epoch // 0' "$latest")"
  age=$(( $(date +%s) - prev_epoch ))
  [ "$age" -lt $(( SKIP_FRESH_HOURS * 3600 )) ] || return 1
  j="$(jq -r '.json_file // empty' "$latest")"
  [ -n "$j" ] && [ -f "$j" ] && echo "$j"
  return 0
}

# ---- run metadata ----------------------------------------------------------
# write_run_meta <dir> <name> <ts> <base> <exit_code> <counts_json>
# Writes <base>.run.json and refreshes .terraform/tfplans/latest.json.
# exit_code follows `terraform plan -detailed-exitcode`: 0 none, 1 error, 2 changes.
write_run_meta() {
  local dir="$1" name="$2" ts="$3" base="$4" rc="$5" counts="$6"
  jq -n \
    --arg name "$name" --arg dir "$dir" --arg ts "$ts" \
    --arg created_at "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
    --argjson created_epoch "$(date +%s)" \
    --arg argv "${RUN_ARGV:-}" \
    --arg profile "${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-}}" \
    --arg tf_version "$(terraform version -json 2>/dev/null | jq -r '.terraform_version // ""')" \
    --arg plan "${base}.tfplan" --arg log "${base}.tfplan.log" --arg json "${base}.tfplan.json" \
    --argjson exit_code "$rc" --argjson summary "$counts" \
    '{ name: $name, dir: $dir, timestamp: $ts, created_at: $created_at,
       created_epoch: $created_epoch, argv: $argv, aws_profile: $profile,
       terraform_version: $tf_version,
       plan_file: $plan, log_file: $log, json_file: $json,
       exit_code: $exit_code, has_changes: ($exit_code == 2), summary: $summary }' \
    > "${base}.run.json"
  cp "${base}.run.json" "${dir}/.terraform/tfplans/latest.json"
}

# ---- apply a saved plan ------------------------------------------------------
# apply_run <run.json> [show_summary=true] [force=false]
#   show_summary=false — skip the banner+summary (caller just printed it)
#   force=true         — skip the confirm prompt (caller already got approval)
# Applies the exact saved .tfplan, tees the output to <base>.apply.<ts>.log,
# and records applied_at/apply_exit/apply_log back into the run metadata.
apply_run() {
  local meta="$1" show_summary="${2:-true}" force="${3:-false}"
  local dir name plan json rc ts log created tmp latest
  dir="$(jq -r '.dir' "$meta")"
  name="$(jq -r '.name' "$meta")"
  plan="$(jq -r '.plan_file' "$meta")"
  json="$(jq -r '.json_file' "$meta")"

  case "$(jq -r '.exit_code' "$meta")" in
    0) info "latest plan for ${name} has no changes — nothing to apply"; return 0 ;;
    1) err "the recorded plan run for ${name} failed — nothing to apply (see $(jq -r '.log_file' "$meta"))"; return 1 ;;
  esac
  if [ ! -f "$plan" ]; then
    err "plan file not found: ${plan} — re-run plan.sh"
    return 1
  fi
  if [ "$(jq -r '.applied_at // empty' "$meta")" != "" ]; then
    warn "this plan was already applied at $(jq -r '.applied_at' "$meta") (exit $(jq -r '.apply_exit' "$meta")) — terraform will reject it if state moved on"
  fi

  if [ "$show_summary" = true ]; then
    banner "tf apply — ${name}"
    created="$(jq -r '.created_epoch // 0' "$meta")"
    info "plan:    ${plan}"
    info "created: $(jq -r '.created_at' "$meta") ($(fmt_age $(( $(date +%s) - created ))) ago)"
    echo
    plan_quick_summary "$json"
    echo
  fi

  if [ "$force" != true ]; then
    confirm "Apply this plan to ${name}?" || { info "not applying ${name}"; return 0; }
  fi

  ensure_aws_auth || return 1

  ts="$(date +"%Y%m%dT%H%M%S")"
  log="${plan%.tfplan}.apply.${ts}.log"
  ( cd "$dir" && terraform apply -input=false "$plan" ) 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}

  # Record the apply on the versioned run.json (and latest.json when it still
  # points at this same plan).
  tmp="$(jq --arg at "$(date +"%Y-%m-%dT%H:%M:%S%z")" --arg log "$log" --argjson rc "$rc" \
        '. + { applied_at: $at, apply_exit: $rc, apply_log: $log }' "$meta")"
  printf '%s\n' "$tmp" > "$meta"
  latest="${dir}/.terraform/tfplans/latest.json"
  if [ -f "$latest" ] && [ "$(jq -r '.plan_file' "$latest")" = "$plan" ]; then
    printf '%s\n' "$tmp" > "$latest"
  fi

  if [ "$rc" -ne 0 ]; then
    if grep -qi 'saved plan is stale' "$log"; then
      err "the saved plan is stale (state changed since it was created) — re-run plan.sh"
    fi
    err "terraform apply failed for ${name} (log: ${log})"
    return 1
  fi
  info "apply complete for ${name} (log: ${log})"
}
