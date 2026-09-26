#!/usr/bin/env bash
# Per-task wall-clock budget snapshot shared by the watcher and crew-state.
# Metadata fields: budget_id, budget_start_epoch, budget_wall_secs, budget_output_tokens.
# FM_BUDGET_NOW_EPOCH is a test-only clock seam; production reads the wall clock.
# A missing/invalid record is not assigned a new start (especially on relaunch).
# No reliable per-task output-token, compaction or restart feed exists yet: report
# unknown rather than guessing from pane text or an aggregate session counter.

FM_BUDGET_DEFAULT_WALL_SECS=21600
FM_BUDGET_DEFAULT_OUTPUT_TOKENS=1000000
FM_BUDGET_REPEAT_SECS=14400

fm_task_budget_positive() {
  case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

fm_task_budget_meta_value() { # <meta> <key>; last occurrence wins
  local line value=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1"
  printf '%s' "$value"
}

fm_task_budget_now() {
  if [ -n "${FM_BUDGET_NOW_EPOCH:-}" ]; then
    case "$FM_BUDGET_NOW_EPOCH" in *[!0-9]*|'') return 1 ;; esac
    printf '%s\n' "$FM_BUDGET_NOW_EPOCH"
  else
    date +%s
  fi
}

fm_task_budget_snapshot() { # <meta> <status-file>; sets FM_BUDGET_* globals
  local meta=$1 status=$2 now line at
  [ -f "$meta" ] || return 1
  FM_BUDGET_START=$(fm_task_budget_meta_value "$meta" budget_start_epoch)
  FM_BUDGET_ID=$(fm_task_budget_meta_value "$meta" budget_id)
  case "$FM_BUDGET_ID" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  FM_BUDGET_WALL_SECS=$(fm_task_budget_meta_value "$meta" budget_wall_secs)
  FM_BUDGET_OUTPUT_TOKENS=$(fm_task_budget_meta_value "$meta" budget_output_tokens)
  fm_task_budget_positive "$FM_BUDGET_START" || return 1
  fm_task_budget_positive "$FM_BUDGET_WALL_SECS" || return 1
  fm_task_budget_positive "$FM_BUDGET_OUTPUT_TOKENS" || return 1
  now=$(fm_task_budget_now) || return 1
  FM_BUDGET_AGE_SECS=$(( now - FM_BUDGET_START ))
  [ "$FM_BUDGET_AGE_SECS" -ge 0 ] || return 1
  FM_BUDGET_TOKENS=unknown
  FM_BUDGET_COMPACTIONS=unknown
  FM_BUDGET_RESTARTS=unknown
  FM_BUDGET_STATUS_GAP_SECS=unknown
  FM_BUDGET_STATUS_LINE=
  if [ -f "$status" ]; then
    line=$(last_status_line "$status")
    FM_BUDGET_STATUS_LINE=$line
    if at=$(status_line_at_epoch "$line") && [ "$at" -le "$now" ]; then
      FM_BUDGET_STATUS_GAP_SECS=$(( now - at ))
    fi
  fi
  FM_BUDGET_PERIOD=-1
  if [ "$FM_BUDGET_AGE_SECS" -ge "$FM_BUDGET_WALL_SECS" ]; then
    FM_BUDGET_PERIOD=$(( (FM_BUDGET_AGE_SECS - FM_BUDGET_WALL_SECS) / FM_BUDGET_REPEAT_SECS ))
  fi
}

fm_task_budget_detail() {
  local gap=$FM_BUDGET_STATUS_GAP_SECS
  [ "$gap" = unknown ] || gap="${gap}s"
  printf 'age=%ss wall_budget=%ss output_budget=%s tokens=%s compactions=%s restarts=%s last_status_ago=%s' \
    "$FM_BUDGET_AGE_SECS" "$FM_BUDGET_WALL_SECS" "$FM_BUDGET_OUTPUT_TOKENS" \
    "$FM_BUDGET_TOKENS" "$FM_BUDGET_COMPACTIONS" "$FM_BUDGET_RESTARTS" "$gap"
}
