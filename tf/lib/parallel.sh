#!/usr/bin/env bash
# lib/parallel.sh — parallel sweep machinery for plan.sh (-j/--parallel N).
# Sourced after lib/common.sh; not executed directly.
#
# Design: each module runs as a background worker doing the same silent
# init -> plan -> export pipeline, reporting through a small key=value status
# file. The monitor keeps N workers running (kill -0 polling; bash 3.2 has no
# `wait -n`), renders a live status region on a tty (plain event lines when
# piped/CI), prints a permanent completion block per module with FULL counts
# (imports/forgets/moves included, zeros shown), pauses and re-queues workers
# that die from expired AWS credentials, and ends with a summary table.
#
# Parallel sweeps are plan-only by design — applies stay serialized through
# apply.sh afterwards.

# auto_jobs — half the cores, clamped to [1,8]: AWS API throttling, not CPU,
# is the practical ceiling for concurrent plans.
auto_jobs() {
  local c
  c="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
  c=$((c / 2))
  [ "$c" -lt 1 ] && c=1
  [ "$c" -gt 8 ] && c=8
  echo "$c"
}

# ---- worker -------------------------------------------------------------------

# status_set <file> <step> [key=value ...] — atomic snapshot of worker state
status_set() {
  local f="$1" step="$2" kv
  shift 2
  {
    echo "step=$step"
    echo "start=${WORKER_START:-$(date +%s)}"
    for kv in "$@"; do echo "$kv"; done
  } > "${f}.tmp" && mv "${f}.tmp" "$f"
}

status_get() { # status_get <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# plan_worker <abs-dir> <name> <status-file> — one module, no console output,
# no prompts (stdin closed). Exit codes: 0 ok (with or without changes),
# 75 credential failure (retryable after a refresh), 1 anything else.
plan_worker() {
  local dir="$1" name="$2" sf="$3"
  local wlog="${sf%.status}.worker.log" ts base rc
  WORKER_START="$(date +%s)"
  exec >>"$wlog" 2>&1 </dev/null

  status_set "$sf" init
  if ! init_module "$dir"; then
    if looks_like_auth_error "$(cat "$wlog")"; then
      status_set "$sf" auth-failed "log=$wlog"
      exit 75
    fi
    status_set "$sf" failed "log=$wlog"
    exit 1
  fi

  mkdir -p "${dir}/.terraform/tfplans"
  ts="$(date +"%Y%m%dT%H%M%S")"
  base="${dir}/.terraform/tfplans/${name}.${ts}"

  status_set "$sf" plan
  ( cd "$dir" && terraform plan -input=false -detailed-exitcode -no-color \
      -out "${base}.tfplan" "${TF_ARGS[@]}" ) > "${base}.tfplan.log" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ]; then
    if looks_like_auth_error "$(cat "${base}.tfplan.log")"; then
      status_set "$sf" auth-failed "log=${base}.tfplan.log"
      exit 75
    fi
    write_run_meta "$dir" "$name" "$ts" "$base" 1 'null'
    status_set "$sf" failed "log=${base}.tfplan.log"
    exit 1
  fi

  status_set "$sf" json
  if ! ( cd "$dir" && terraform show -json "${base}.tfplan" ) > "${base}.tfplan.json"; then
    status_set "$sf" failed "log=$wlog"
    exit 1
  fi
  cp "${base}.tfplan.json" "${dir}/.terraform/latest.tfplan.json"
  write_run_meta "$dir" "$name" "$ts" "$base" "$rc" "$(plan_counts "${base}.tfplan.json")"
  status_set "$sf" done "meta=${base}.run.json" "json=${base}.tfplan.json"
  exit 0
}

# ---- rendering ----------------------------------------------------------------

step_label() {
  case "$1" in
    init)   echo "initializing" ;;
    plan)   echo "planning" ;;
    json)   echo "exporting json" ;;
    queued) echo "starting" ;;
    *)      echo "${1:-starting}" ;;
  esac
}

# The live region is DRAWN lines tall; erase before printing anything permanent.
_erase_region() {
  [ "${DRAWN:-0}" -gt 0 ] && printf '\033[%dA\033[J' "$DRAWN"
  DRAWN=0
}

_draw_region() {
  [ "$IS_TTY" = true ] || return 0
  local i now lines=1 sf st ws
  now="$(date +%s)"
  printf 'running: %d   done: %d   failed: %d   queued: %d   elapsed %s\n' \
    "${#RUN_PIDS[@]}" "$N_DONE" "$N_FAIL" "${#QUEUE[@]}" "$(fmt_age $((now - SWEEP_START)))"
  i=0
  while [ "$i" -lt "${#RUN_PIDS[@]}" ]; do
    sf="${RUN_SFS[$i]}"
    st="$(status_get "$sf" step)"
    ws="$(status_get "$sf" start)"; ws="${ws:-$now}"
    printf '  %-28s %-16s %4ss\n' "${RUN_NAMES[$i]}" "$(step_label "$st")" "$((now - ws))"
    lines=$((lines + 1))
    i=$((i + 1))
  done
  DRAWN=$lines
}

# full_counts <run.json> — every bucket, zeros included: the buckets that the
# normal summary hides (imports, forgets, moves) always show here.
full_counts() {
  jq -r '.summary
         | "create \(.create) · update \(.update) · destroy \(.destroy) · replace \(.replace) · import \(.import) · forget \(.forget) · move \(.move)"' \
    "$1"
}

_print_done_block() { # name dur meta json
  local name="$1" dur="$2" meta="$3" json="$4" summary
  hr
  echo "$(paint 32 "✔") ${name}  ($(fmt_age "$dur"))"
  echo "   plan: $(jq -r '.plan_file' "$meta")"
  echo "   $(full_counts "$meta")"
  summary="$(plan_quick_summary "$json")"
  case "$summary" in
    "No changes."*) echo "   no changes" ;;
    *) printf '%s\n' "$summary" | sed '1d; s/^/ /' ;;
  esac
  echo
}

_print_fail_block() { # name dur log why
  local name="$1" dur="$2" log="$3" why="$4"
  hr
  echo "$(paint 31 "✖") ${name}  ($(fmt_age "$dur")) — ${why}"
  if [ -n "$log" ] && [ -f "$log" ]; then
    echo "   log: $log"
    tail -5 "$log" | sed 's/^/   | /'
  fi
  echo
}

_summary_row() { # name meta dur -> "name|result|c|u|d|r|i|f|m|time"
  jq -r --arg n "$1" --arg t "$(fmt_age "$3")" \
    '.summary as $s
     | [$n, (if .exit_code == 2 then "changes" else "clean" end),
        ($s.create|tostring), ($s.update|tostring), ($s.destroy|tostring),
        ($s.replace|tostring), ($s.import|tostring), ($s.forget|tostring),
        ($s.move|tostring), $t]
     | join("|")' "$2"
}

parallel_summary_table() {
  [ "${#SUMMARY_ROWS[@]}" -eq 0 ] && return 0
  echo
  banner "sweep summary"
  {
    echo "module|result|create|update|destroy|replace|import|forget|move|time"
    local r
    for r in "${SUMMARY_ROWS[@]}"; do echo "$r"; done
  } | column -t -s '|'
  echo
}

# ---- monitor ------------------------------------------------------------------

_parallel_abort() {
  trap - INT TERM
  [ "${#RUN_PIDS[@]}" -gt 0 ] && kill "${RUN_PIDS[@]}" 2>/dev/null
  _erase_region
  err "sweep interrupted — ${N_DONE} done, ${#QUEUE[@]} still queued"
  exit 130
}

# _harvest <name> <status-file> <dir> <rc> — account for one finished worker
_harvest() {
  local name="$1" sf="$2" dir="$3" rc="$4" meta json dur start now
  now="$(date +%s)"
  start="$(status_get "$sf" start)"; start="${start:-$now}"
  dur=$((now - start))
  case "$rc" in
    0)
      meta="$(status_get "$sf" meta)"
      json="$(status_get "$sf" json)"
      PLANNED_JSONS+=("$json")
      N_DONE=$((N_DONE + 1))
      _erase_region
      _print_done_block "$name" "$dur" "$meta" "$json"
      SUMMARY_ROWS+=("$(_summary_row "$name" "$meta" "$dur")")
      ;;
    75)
      case " $RETRIED " in
        *" $name "*) # already re-queued once — give up on it
          N_FAIL=$((N_FAIL + 1))
          _erase_region
          _print_fail_block "$name" "$dur" "$(status_get "$sf" log)" "credentials expired again after refresh"
          SUMMARY_ROWS+=("${name}|auth-failed|-|-|-|-|-|-|-|$(fmt_age "$dur")")
          ;;
        *)
          RETRIED="$RETRIED $name"
          AUTHQ_DIRS+=("$dir")
          PAUSED=true
          _erase_region
          warn "${name}: AWS credentials expired — pausing new launches for a refresh"
          ;;
      esac
      ;;
    *)
      N_FAIL=$((N_FAIL + 1))
      _erase_region
      _print_fail_block "$name" "$dur" "$(status_get "$sf" log)" "failed (exit $rc)"
      SUMMARY_ROWS+=("${name}|failed|-|-|-|-|-|-|-|$(fmt_age "$dur")")
      ;;
  esac
}

# parallel_sweep <jobs> — consumes QUEUE[] (absolute module dirs), appends to
# PLANNED_JSONS[] and SUMMARY_ROWS[]. Returns nonzero if any module failed.
parallel_sweep() {
  local jobs="$1" statusdir dir name sf pid rc i
  local keep_pids keep_names keep_sfs keep_dirs
  statusdir="$(mktemp -d "${TMPDIR:-/tmp}/tfplan-sweep.XXXXXX")"
  SWEEP_START="$(date +%s)"
  RUN_PIDS=(); RUN_NAMES=(); RUN_SFS=(); RUN_DIRS=()
  AUTHQ_DIRS=(); SUMMARY_ROWS=(); RETRIED=""
  N_DONE=0; N_FAIL=0; DRAWN=0; PAUSED=false
  if [ -t 1 ]; then IS_TTY=true; else IS_TTY=false; fi
  trap '_parallel_abort' INT TERM

  while [ "${#QUEUE[@]}" -gt 0 ] || [ "${#RUN_PIDS[@]}" -gt 0 ]; do
    # fill free slots (unless paused for a credential refresh)
    while [ "$PAUSED" = false ] && [ "${#RUN_PIDS[@]}" -lt "$jobs" ] && [ "${#QUEUE[@]}" -gt 0 ]; do
      dir="${QUEUE[0]}"
      QUEUE=("${QUEUE[@]:1}")
      name="$(basename "$dir")"
      sf="${statusdir}/${name}.status"
      status_set "$sf" queued
      plan_worker "$dir" "$name" "$sf" &
      RUN_PIDS+=($!); RUN_NAMES+=("$name"); RUN_SFS+=("$sf"); RUN_DIRS+=("$dir")
      [ "$IS_TTY" = true ] || echo "> ${name}: started"
    done

    # harvest finished workers
    keep_pids=(); keep_names=(); keep_sfs=(); keep_dirs=()
    i=0
    while [ "$i" -lt "${#RUN_PIDS[@]}" ]; do
      pid="${RUN_PIDS[$i]}"
      if kill -0 "$pid" 2>/dev/null; then
        keep_pids+=("$pid")
        keep_names+=("${RUN_NAMES[$i]}")
        keep_sfs+=("${RUN_SFS[$i]}")
        keep_dirs+=("${RUN_DIRS[$i]}")
      else
        wait "$pid"; rc=$?
        _harvest "${RUN_NAMES[$i]}" "${RUN_SFS[$i]}" "${RUN_DIRS[$i]}" "$rc"
      fi
      i=$((i + 1))
    done
    RUN_PIDS=("${keep_pids[@]}")
    RUN_NAMES=("${keep_names[@]}")
    RUN_SFS=("${keep_sfs[@]}")
    RUN_DIRS=("${keep_dirs[@]}")

    # paused: let in-flight workers drain, then prompt once and re-queue
    if [ "$PAUSED" = true ] && [ "${#RUN_PIDS[@]}" -eq 0 ]; then
      _erase_region
      if [ -t 0 ] && ensure_aws_auth; then
        for dir in "${AUTHQ_DIRS[@]}"; do QUEUE+=("$dir"); done
        info "re-queued ${#AUTHQ_DIRS[@]} module(s) after credential refresh"
      else
        for dir in "${AUTHQ_DIRS[@]}"; do
          name="$(basename "$dir")"
          N_FAIL=$((N_FAIL + 1))
          SUMMARY_ROWS+=("${name}|auth-failed|-|-|-|-|-|-|-|-")
          err "${name}: AWS credentials expired and no tty to wait for a refresh"
        done
      fi
      AUTHQ_DIRS=()
      PAUSED=false
      continue
    fi

    [ "${#QUEUE[@]}" -eq 0 ] && [ "${#RUN_PIDS[@]}" -eq 0 ] && break
    _erase_region
    _draw_region
    sleep 0.5
  done

  _erase_region
  trap - INT TERM
  rm -rf "$statusdir"
  [ "$N_FAIL" -eq 0 ]
}
