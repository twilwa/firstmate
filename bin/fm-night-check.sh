#!/usr/bin/env bash
# fm-night-check.sh - overnight stop-and-health check and herdr-core (hc)
# night guard.
#
# Single owner of the overnight stop-condition evaluation, its durable night
# records under state/, its machine-readable verdict document for the morning
# board (P3) and two-hour default gate (P2), and the hc night guard that
# refuses herdr-core upgrades or stops while a night is active.
#
# Usage:
#   fm-night-check.sh [check] [--json]
#   fm-night-check.sh verdict [--json]
#   fm-night-check.sh start
#   fm-night-check.sh end
#   fm-night-check.sh record-validation <id>
#   fm-night-check.sh hc-guard
#   fm-night-check.sh --help
#
# Verdicts (ordered from least to most severe; the most severe tripped
# condition wins):
#   continue       All evaluated conditions are healthy; dispatch, Claude work,
#                  merges, validations, and two-hour defaults may proceed.
#   stop_claude    ("stop new Claude work") Stop new Claude-harness work and
#                  validations (e.g. Claude 5h/weekly quota < 25% or validation
#                  cap reached); non-Claude builders may still dispatch, so
#                  reserve-flag is not set.
#   stop_dispatch  ("stop new dispatch") Admit no new work at all (e.g. past
#                  last-dispatch cut-off, Claude quota < 12%, GitHub core API
#                  < 1000, failure streak >= 3, failed post-merge check, >= 2
#                  finished PRs waiting for a check slot, supervision stall,
#                  sustained high host load, or ANY unreadable/unknown source);
#                  sets the first configured reserve-flag in config/lane-capacity
#                  so bin/fm-capacity.sh admits nothing new.
#   end_night      ("end the night") The night is over (outside the configured
#                  night window or hc core restarted); disallows dispatch,
#                  Claude work, merges, validations, and two-hour defaults, and
#                  sets reserve-flag.
#
# Non-destructive guarantee: this script never kills, interrupts, or tears down
# any worker, terminal, or service. When a stop condition trips it writes the
# durable night stop record under state/ through one owner path and (whenever
# allow.dispatch is false) creates the existing reserve-flag from
# config/lane-capacity.
#
# Unreadable-source invariant: any source that cannot be read, times out, or
# returns malformed data reports that condition as status="unknown" with
# verdict_effect="stop_dispatch"; it never reads as healthy.
#
# Durable state files under $STATE (written atomically, mode 0600, owned solely
# by this script):
#   state/night-active.json   (schema: fm-night-active.v1)
#     Present while a night is on. Written by `start`, removed by `end`.
#     Carries started_epoch, started_at, resolved window settings, optional
#     hc_baseline {pid, core_id, holder_instance, uptime_ms, started_epoch},
#     and recorded validation run ids. While present (or if unreadable/corrupt),
#     `hc-guard` refuses herdr-core installs and core stops.
#   state/night-verdict.json  (schema: fm-night-verdict.v1)
#     Latest evaluation verdict, rewritten atomically on every `check` and
#     served by `verdict [--json]` without re-polling external tools.
#     Machine-readable shape consumed by P2 (check allow.two_hour_default) and
#     P3 (morning board):
#       {
#         "schema": "fm-night-verdict.v1",
#         "checked_epoch": <int>,
#         "checked_at": "<UTC ISO-8601>",
#         "night_active": <bool>,
#         "night_started_epoch": <int|null>,
#         "verdict": "continue"|"stop_claude"|"stop_dispatch"|"end_night",
#         "verdict_label": "<human verdict phrase>",
#         "allow": {
#           "dispatch": <bool>,
#           "claude": <bool>,
#           "merge": <bool>,
#           "validation": <bool>,
#           "two_hour_default": <bool>
#         },
#         "tripped": [
#           {
#             "condition": "<name>",
#             "status": "tripped"|"unknown",
#             "verdict_effect": "stop_claude"|"stop_dispatch"|"end_night",
#             "reason": "<plain-text reason>"
#           }
#         ],
#         "reasons": ["<plain-text reason>", ...],
#         "conditions": {
#           "night_window":      { "status", "verdict_effect", "reason", "details" },
#           "claude_quota":      { "status", "verdict_effect", "reason", "details" },
#           "github_api":        { "status", "verdict_effect", "reason", "details" },
#           "failure_streak":    { "status", "verdict_effect", "reason", "details" },
#           "dev_health":        { "status", "verdict_effect", "reason", "details" },
#           "check_machine":     { "status", "verdict_effect", "reason", "details" },
#           "validation_cap":    { "status", "verdict_effect", "reason", "details" },
#           "supervision_stall": { "status", "verdict_effect", "reason", "details" },
#           "hc_core":           { "status", "verdict_effect", "reason", "details" },
#           "host_load":         { "status", "verdict_effect", "reason", "details" }
#         },
#         "reserve_flag": {
#           "configured": <bool>,
#           "path": "<abs-path|null>",
#           "set_by_check": <bool>
#         },
#         "stop_record_path": "<abs-path|null>"
#       }
#   state/night-stop.json     (schema: fm-night-stop.v1)
#     Durable stop record written by the single owner helper whenever any
#     condition trips (verdict != "continue"). Preserves first_tripped_epoch,
#     stall_since_epoch (when supervision_stall tripped), core_restarted
#     (when hc_core tripped), latest verdict, and tripped reasons. Kept after
#     `end` so the morning board can read why the night stopped; cleared when
#     a new night starts via `start`.
#
# Home configuration: config/night-check (local, gitignored, home-local; schema
# owned by docs/configuration.md "Night stop-and-health check").
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_DATA_OVERRIDE
#   FM_NIGHT_NOW_EPOCH       override current epoch seconds (tests)
#   FM_PROC_ROOT_OVERRIDE    override /proc root for Linux loadavg (tests)
#   FM_REVIEW_POLICY_OVERRIDE override review policy path (tests)
#   FM_HC_BIN                override herdr-core binary path (matching hc.sh)
#
# Exit status:
#   check / start / end / record-validation: 0 on completion, 1 on refusal or
#     state error, 2 on usage error or missing jq.
#   verdict: 0 when a valid latest verdict exists, 1 when absent or corrupt.
#   hc-guard: 0 when no night is active, 1 with refusal reason on stderr when
#     a night is active (or state/night-active.json is unreadable/corrupt).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
NIGHT_CONFIG="$CONFIG/night-check"
LANE_CONFIG="$CONFIG/lane-capacity"
ACTIVE_FILE="$STATE/night-active.json"
VERDICT_FILE="$STATE/night-verdict.json"
STOP_FILE="$STATE/night-stop.json"
POLICY_FILE="${FM_REVIEW_POLICY_OVERRIDE:-$FM_ROOT/.github/firstmate-review-policy.json}"
PROC_ROOT="${FM_PROC_ROOT_OVERRIDE:-/proc}"

# Defaults (docs/configuration.md "Night stop-and-health check")
WINDOW_START="23:00"
LAST_DISPATCH="06:30"
WINDOW_END="07:30"
WINDOW_TZ="America/Los_Angeles"
CLAUDE_STOP_CLAUDE_PCT=25
CLAUDE_STOP_ALL_PCT=12
GITHUB_API_FLOOR=1000
FAILURE_STREAK_LIMIT=3
CHECK_QUEUE_LIMIT=2
VALIDATION_CAP=2
STALL_MINUTES=30
HIGH_LOAD_THRESHOLD=24
HIGH_LOAD_MINUTES=10
QUOTA_TIMEOUT="${FM_NIGHT_QUOTA_TIMEOUT:-10}"
GH_TIMEOUT="${FM_NIGHT_GH_TIMEOUT:-10}"
HC_TIMEOUT="${FM_NIGHT_HC_TIMEOUT:-10}"

CONFIG_ERROR=

load_check_libs() {
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  # shellcheck source=bin/fm-quota-axi-lib.sh
  . "$SCRIPT_DIR/fm-quota-axi-lib.sh"
}

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() {
  printf 'fm-night-check: %s\n' "$*" >&2
  exit 1
}

die_usage() {
  printf 'fm-night-check: %s\n' "$*" >&2
  printf 'usage: fm-night-check.sh [check [--json] | verdict [--json] | start | end | record-validation <id> | hc-guard | --help]\n' >&2
  exit 2
}

is_uint() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

is_num() {
  case "${1:-}" in ''|*[!0-9.]*|*.*.*|.*|*.) return 1 ;; esac
}

is_hhmm() {
  local v=${1:-} h m
  case "$v" in
    [0-9][0-9]:[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  h=$((10#${v%:*}))
  m=$((10#${v#*:}))
  [ "$h" -ge 0 ] && [ "$h" -le 23 ] && [ "$m" -ge 0 ] && [ "$m" -le 59 ]
}

hhmm_to_minutes() {
  local v=$1
  printf '%s\n' $(( 10#${v%:*} * 60 + 10#${v#*:} ))
}

now_epoch() {
  if [ -n "${FM_NIGHT_NOW_EPOCH:-}" ]; then
    is_uint "$FM_NIGHT_NOW_EPOCH" || die "FM_NIGHT_NOW_EPOCH must be an unsigned integer"
    printf '%s\n' "$FM_NIGHT_NOW_EPOCH"
  else
    date -u +%s
  fi
}

epoch_to_iso() {
  local e=$1 out
  out=$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || \
    out=$(date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || \
    out="1970-01-01T00:00:00Z"
  printf '%s\n' "$out"
}

epoch_to_tz_hhmm() {
  local e=$1 tz=$2 out
  out=$(TZ="$tz" date -d "@$e" '+%H:%M' 2>/dev/null) || \
    out=$(TZ="$tz" date -r "$e" '+%H:%M' 2>/dev/null) || \
    return 1
  is_hhmm "$out" || return 1
  printf '%s\n' "$out"
}

file_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=""
  is_uint "$m" || m=$(/usr/bin/stat -f %m "$1" 2>/dev/null) || m=""
  is_uint "$m" && printf '%s\n' "$m"
}

iso_to_epoch() {
  local s=${1:-} out
  [ -n "$s" ] || return 1
  out=$(date -u -d "$s" +%s 2>/dev/null) || \
    out=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$s" +%s 2>/dev/null) || \
    return 1
  is_uint "$out" || return 1
  printf '%s\n' "$out"
}

LEDGER_DIR=""
LEDGER_DIR_ERROR=""
resolve_ledger_dir() {
  local rel
  LEDGER_DIR=""
  LEDGER_DIR_ERROR=""
  if [ ! -f "$POLICY_FILE" ] || [ -L "$POLICY_FILE" ] || [ ! -r "$POLICY_FILE" ]; then
    LEDGER_DIR_ERROR="review policy configuration at $POLICY_FILE is unavailable"
    return 1
  fi
  rel=$(jq -er '.ledger_directory | select(type == "string" and length > 0)' "$POLICY_FILE" 2>/dev/null) || {
    LEDGER_DIR_ERROR="review policy ledger_directory is invalid"
    return 1
  }
  case "$rel" in
    /*|.|..|*/../*|../*|*/..|*//*|*[!A-Za-z0-9._/-]*)
      LEDGER_DIR_ERROR="review policy ledger_directory is unsafe"
      return 1
      ;;
  esac
  LEDGER_DIR="$DATA/$rel"
  return 0
}

atomic_write_json() {  # <dest> <content>
  local dest=$1 content=$2 dir tmp
  dir=$(dirname "$dest")
  mkdir -p "$dir" 2>/dev/null || return 1
  [ ! -L "$dest" ] || return 1
  tmp=$(mktemp "$dir/.fm-night-tmp.XXXXXX" 2>/dev/null) || return 1
  if chmod 0600 "$tmp" 2>/dev/null && printf '%s\n' "$content" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

in_time_interval() {  # <cur_min> <start_min> <end_min> (half-open [start, end))
  local cur=$1 start=$2 end=$3
  if [ "$start" -lt "$end" ]; then
    [ "$cur" -ge "$start" ] && [ "$cur" -lt "$end" ]
  elif [ "$start" -gt "$end" ]; then
    [ "$cur" -ge "$start" ] || [ "$cur" -lt "$end" ]
  else
    return 1
  fi
}

# --- config/night-check parser ----------------------------------------------
parse_night_config() {
  local line lineno=0 key rest value seen=""
  local s_min l_min e_min
  CONFIG_ERROR=
  [ -e "$NIGHT_CONFIG" ] || return 0
  if [ ! -f "$NIGHT_CONFIG" ] || [ -L "$NIGHT_CONFIG" ] || [ ! -r "$NIGHT_CONFIG" ]; then
    CONFIG_ERROR="config/night-check is unreadable or unsafe"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr '\t\r' '  ' | sed 's/^ *//; s/ *$//')
    [ -n "$line" ] || continue
    key=${line%% *}
    rest=
    [ "$key" = "$line" ] || rest=$(printf '%s' "${line#* }" | sed 's/^ *//')
    value=${rest%% *}
    case " $seen " in
      *" $key "*) CONFIG_ERROR="config/night-check line $lineno: duplicate key '$key'"; return 1 ;;
    esac
    seen="$seen $key"
    if [ -z "$value" ] || [ "$value" != "$rest" ]; then
      CONFIG_ERROR="config/night-check line $lineno: '$key' requires exactly one value"
      return 1
    fi
    case "$key" in
      window-start)
        is_hhmm "$value" || { CONFIG_ERROR="config/night-check line $lineno: window-start must be HH:MM (00:00-23:59)"; return 1; }
        WINDOW_START=$value
        ;;
      last-dispatch)
        is_hhmm "$value" || { CONFIG_ERROR="config/night-check line $lineno: last-dispatch must be HH:MM (00:00-23:59)"; return 1; }
        LAST_DISPATCH=$value
        ;;
      window-end)
        is_hhmm "$value" || { CONFIG_ERROR="config/night-check line $lineno: window-end must be HH:MM (00:00-23:59)"; return 1; }
        WINDOW_END=$value
        ;;
      timezone)
        case "$value" in
          ''|*..*|*[!A-Za-z0-9._+/:-]*)
            CONFIG_ERROR="config/night-check line $lineno: invalid timezone '$value'"
            return 1
            ;;
        esac
        WINDOW_TZ=$value
        ;;
      claude-stop-claude-pct)
        if ! is_num "$value" || ! jq -en --arg v "$value" '($v|tonumber) >= 0 and ($v|tonumber) <= 100' >/dev/null 2>&1; then
          CONFIG_ERROR="config/night-check line $lineno: claude-stop-claude-pct must be 0..100"
          return 1
        fi
        CLAUDE_STOP_CLAUDE_PCT=$value
        ;;
      claude-stop-all-pct)
        if ! is_num "$value" || ! jq -en --arg v "$value" '($v|tonumber) >= 0 and ($v|tonumber) <= 100' >/dev/null 2>&1; then
          CONFIG_ERROR="config/night-check line $lineno: claude-stop-all-pct must be 0..100"
          return 1
        fi
        CLAUDE_STOP_ALL_PCT=$value
        ;;
      github-api-floor)
        is_uint "$value" || { CONFIG_ERROR="config/night-check line $lineno: github-api-floor must be an integer"; return 1; }
        GITHUB_API_FLOOR=$((10#$value))
        ;;
      failure-streak-limit)
        is_uint "$value" && [ "$((10#$value))" -ge 1 ] || { CONFIG_ERROR="config/night-check line $lineno: failure-streak-limit must be >= 1"; return 1; }
        FAILURE_STREAK_LIMIT=$((10#$value))
        ;;
      check-queue-limit)
        is_uint "$value" && [ "$((10#$value))" -ge 1 ] || { CONFIG_ERROR="config/night-check line $lineno: check-queue-limit must be >= 1"; return 1; }
        CHECK_QUEUE_LIMIT=$((10#$value))
        ;;
      validation-cap)
        is_uint "$value" && [ "$((10#$value))" -ge 1 ] || { CONFIG_ERROR="config/night-check line $lineno: validation-cap must be >= 1"; return 1; }
        VALIDATION_CAP=$((10#$value))
        ;;
      stall-minutes)
        is_uint "$value" && [ "$((10#$value))" -ge 1 ] || { CONFIG_ERROR="config/night-check line $lineno: stall-minutes must be >= 1"; return 1; }
        STALL_MINUTES=$((10#$value))
        ;;
      high-load-threshold)
        is_num "$value" || { CONFIG_ERROR="config/night-check line $lineno: high-load-threshold must be a non-negative number"; return 1; }
        HIGH_LOAD_THRESHOLD=$value
        ;;
      high-load-minutes)
        is_uint "$value" && [ "$((10#$value))" -ge 1 ] || { CONFIG_ERROR="config/night-check line $lineno: high-load-minutes must be >= 1"; return 1; }
        HIGH_LOAD_MINUTES=$((10#$value))
        ;;
      *)
        CONFIG_ERROR="config/night-check line $lineno: unknown key '$key'"
        return 1
        ;;
    esac
  done < "$NIGHT_CONFIG"

  if ! jq -en --arg a "$CLAUDE_STOP_ALL_PCT" --arg c "$CLAUDE_STOP_CLAUDE_PCT" '($a|tonumber) <= ($c|tonumber)' >/dev/null 2>&1; then
    CONFIG_ERROR="config/night-check: claude-stop-all-pct ($CLAUDE_STOP_ALL_PCT) cannot exceed claude-stop-claude-pct ($CLAUDE_STOP_CLAUDE_PCT)"
    return 1
  fi
  s_min=$(hhmm_to_minutes "$WINDOW_START")
  l_min=$(hhmm_to_minutes "$LAST_DISPATCH")
  e_min=$(hhmm_to_minutes "$WINDOW_END")
  if [ "$s_min" -eq "$e_min" ]; then
    CONFIG_ERROR="config/night-check: window-start and window-end cannot be identical"
    return 1
  fi
  if [ "$l_min" -ne "$e_min" ] && ! in_time_interval "$l_min" "$s_min" "$e_min"; then
    CONFIG_ERROR="config/night-check: last-dispatch ($LAST_DISPATCH) must fall within [$WINDOW_START, $WINDOW_END]"
    return 1
  fi
  return 0
}

# --- config/lane-capacity reserve-flag reader -------------------------------
expand_home_path() {
  case "${1:-}" in
    \~/*) printf '%s\n' "${HOME:-}/${1#\~/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

first_lane_reserve_flag() {
  local line key rest value path
  [ -f "$LANE_CONFIG" ] && [ -r "$LANE_CONFIG" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr '\t\r' '  ' | sed 's/^ *//; s/ *$//')
    [ -n "$line" ] || continue
    key=${line%% *}
    [ "$key" = "reserve-flag" ] || continue
    [ "$key" != "$line" ] || continue
    rest=$(printf '%s' "${line#* }" | sed 's/^ *//')
    value=${rest%% *}
    path=$(expand_home_path "$value") || continue
    printf '%s\n' "$path"
    return 0
  done < "$LANE_CONFIG"
  return 1
}

set_lane_reserve_flag() {  # <path> <verdict> <now_iso> <reasons_summary>
  local path=$1 verdict=$2 iso=$3 summary=$4 dir tmp
  dir=$(dirname "$path")
  mkdir -p "$dir" 2>/dev/null || return 1
  [ ! -L "$path" ] || return 1
  tmp=$(mktemp "$dir/.fm-night-reserve.XXXXXX" 2>/dev/null) || return 1
  if chmod 0600 "$tmp" 2>/dev/null \
    && printf 'set_by=fm-night-check\nat=%s\nverdict=%s\nreasons=%s\n' "$iso" "$verdict" "$summary" > "$tmp" 2>/dev/null \
    && mv -f -- "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

# --- hc-guard (fast path, no jq needed when night-active.json absent) -------
cmd_hc_guard() {
  if [ ! -e "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ]; then
    exit 0
  fi
  if [ -L "$ACTIVE_FILE" ] || [ ! -f "$ACTIVE_FILE" ] || [ ! -r "$ACTIVE_FILE" ]; then
    printf 'fm-night-check: hc core operation refused: %s exists but is unreadable or unsafe (failing closed)\n' "$ACTIVE_FILE" >&2
    exit 1
  fi
  local started_at=""
  if type -P jq >/dev/null 2>&1; then
    started_at=$(jq -r 'if .schema == "fm-night-active.v1" and (.started_at | type == "string") then .started_at else "" end' "$ACTIVE_FILE" 2>/dev/null) || started_at=""
  fi
  if [ -n "$started_at" ]; then
    printf 'fm-night-check: hc core operation refused while overnight run is active (started %s; run bin/fm-night-check.sh end first)\n' "$started_at" >&2
  else
    printf 'fm-night-check: hc core operation refused while overnight run marker %s is present (run bin/fm-night-check.sh end first)\n' "$ACTIVE_FILE" >&2
  fi
  exit 1
}

# --- start / end / verdict / record-validation ------------------------------
hc_backend_configured() {
  if [ "${FM_BACKEND:-}" = "hc" ]; then
    return 0
  fi
  if [ -f "$CONFIG/backend" ] && [ ! -L "$CONFIG/backend" ] && [ -r "$CONFIG/backend" ]; then
    local val
    val=$(sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$CONFIG/backend" 2>/dev/null | awk 'NF { print $1; exit }')
    [ "$val" = "hc" ] && return 0
  fi
  return 1
}

hc_resolve_bin() {
  if [ -n "${FM_HC_BIN:-}" ]; then
    [ -x "$FM_HC_BIN" ] || return 1
    printf '%s\n' "$FM_HC_BIN"
    return 0
  fi
  type -P herdr-core 2>/dev/null && return 0
  type -P hc 2>/dev/null && return 0
  return 1
}

read_hc_status_json() {  # <now> -> prints normalized hc status object or returns 1
  local now=$1 hbin json rc=0 parsed
  hbin=$(hc_resolve_bin) || return 1
  json=$(
    unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
    fm_run_timed "$HC_TIMEOUT" "$hbin" server status --json 2>/dev/null </dev/null
  ) || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$json" ] || return 1
  # shellcheck disable=SC2016
  parsed=$(printf '%s\n' "$json" | jq -c --argjson now "$now" '
    if (type == "object")
       and (.pid | type == "number" and . > 0 and floor == .)
       and (.uptime_ms | type == "number" and . >= 0) then
      {
        pid: .pid,
        core_id: (.core.id // ""),
        holder_instance: (.holder.instance // ""),
        uptime_ms: .uptime_ms,
        started_epoch: ($now - ((.uptime_ms / 1000) | floor))
      }
    else empty end
  ' 2>/dev/null) || return 1
  [ -n "$parsed" ] || return 1
  printf '%s\n' "$parsed"
}

cmd_start() {
  type -P jq >/dev/null 2>&1 || die_usage "jq is required"
  load_check_libs
  if [ -e "$ACTIVE_FILE" ] || [ -L "$ACTIVE_FILE" ]; then
    die "a night run is already active ($ACTIVE_FILE); run 'end' before starting a new night"
  fi
  parse_night_config || die "$CONFIG_ERROR"
  local now iso hc_base=null doc
  now=$(now_epoch)
  iso=$(epoch_to_iso "$now")
  if hc_backend_configured; then
    hc_base=$(read_hc_status_json "$now") || die "backend=hc is configured but herdr-core server status could not be read for baseline"
  fi
  doc=$(jq -n \
    --argjson now "$now" \
    --arg iso "$iso" \
    --arg ws "$WINDOW_START" \
    --arg ld "$LAST_DISPATCH" \
    --arg we "$WINDOW_END" \
    --arg tz "$WINDOW_TZ" \
    --argjson hc_base "$hc_base" \
    '{
      schema: "fm-night-active.v1",
      started_epoch: $now,
      started_at: $iso,
      window: {
        start: $ws,
        last_dispatch: $ld,
        end: $we,
        timezone: $tz
      },
      hc_baseline: $hc_base,
      validations: []
    }') || die "could not build night-active record"
  atomic_write_json "$ACTIVE_FILE" "$doc" || die "could not write $ACTIVE_FILE"
  rm -f -- "$STOP_FILE" 2>/dev/null || true
  printf 'night-check: started at %s (window %s-%s, last-dispatch %s %s)\n' \
    "$iso" "$WINDOW_START" "$WINDOW_END" "$LAST_DISPATCH" "$WINDOW_TZ"
}

cmd_end() {
  if [ ! -e "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ]; then
    printf 'night-check: no active night run\n'
    exit 0
  fi
  rm -f -- "$ACTIVE_FILE" || die "could not remove $ACTIVE_FILE"
  printf 'night-check: ended active night run\n'
}

cmd_verdict() {
  local want_json=0
  if [ "${1:-}" = "--json" ]; then
    want_json=1
    shift
  fi
  [ "$#" -eq 0 ] || die_usage "unexpected arguments to verdict"
  type -P jq >/dev/null 2>&1 || die_usage "jq is required"
  [ -f "$VERDICT_FILE" ] && [ ! -L "$VERDICT_FILE" ] && [ -r "$VERDICT_FILE" ] \
    || die "no stored night verdict at $VERDICT_FILE"
  jq -e '.schema == "fm-night-verdict.v1" and (.verdict | type == "string")' "$VERDICT_FILE" >/dev/null 2>&1 \
    || die "stored night verdict at $VERDICT_FILE is corrupt"
  if [ "$want_json" -eq 1 ]; then
    cat "$VERDICT_FILE"
  else
    render_human_verdict "$VERDICT_FILE"
  fi
}

cmd_record_validation() {
  local id=${1:-}
  [ -n "$id" ] && [ "$#" -eq 1 ] || die_usage "record-validation requires one run id"
  type -P jq >/dev/null 2>&1 || die_usage "jq is required"
  [ -f "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ] && [ -r "$ACTIVE_FILE" ] \
    || die "no active night record at $ACTIVE_FILE"
  local now updated
  now=$(now_epoch)
  updated=$(jq --arg id "$id" --argjson now "$now" '
    if .schema != "fm-night-active.v1" then error("invalid") else . end
    | .validations = ((.validations // []) | if any(.[]; .id == $id) then . else . + [{id: $id, recorded_epoch: $now}] end)
  ' "$ACTIVE_FILE" 2>/dev/null) || die "could not update $ACTIVE_FILE"
  atomic_write_json "$ACTIVE_FILE" "$updated" || die "could not write $ACTIVE_FILE"
  printf 'night-check: recorded validation %s\n' "$id"
}

# --- Condition evaluators ---------------------------------------------------
cond_json() {  # <status> <verdict_effect> <reason> <details_json>
  jq -cn \
    --arg status "$1" \
    --arg effect "$2" \
    --arg reason "$3" \
    --argjson details "${4:-null}" \
    '{status: $status, verdict_effect: $effect, reason: $reason, details: $details}'
}

eval_night_window() {  # <now> <active_bad>
  local now=$1 active_bad=$2
  if [ -n "$CONFIG_ERROR" ]; then
    cond_json unknown stop_dispatch "$CONFIG_ERROR" '{}'
    return 0
  fi
  if [ "$active_bad" -eq 1 ]; then
    cond_json unknown stop_dispatch "state/night-active.json is unreadable or corrupt" '{}'
    return 0
  fi
  local cur_hhmm cur_min start_min last_min end_min details
  if ! cur_hhmm=$(epoch_to_tz_hhmm "$now" "$WINDOW_TZ"); then
    cond_json unknown stop_dispatch "could not convert epoch $now to timezone $WINDOW_TZ" '{}'
    return 0
  fi
  cur_min=$(hhmm_to_minutes "$cur_hhmm")
  start_min=$(hhmm_to_minutes "$WINDOW_START")
  last_min=$(hhmm_to_minutes "$LAST_DISPATCH")
  end_min=$(hhmm_to_minutes "$WINDOW_END")
  details=$(jq -cn \
    --arg cur "$cur_hhmm" --arg tz "$WINDOW_TZ" \
    --arg ws "$WINDOW_START" --arg ld "$LAST_DISPATCH" --arg we "$WINDOW_END" \
    '{local_time: $cur, timezone: $tz, window_start: $ws, last_dispatch: $ld, window_end: $we}')
  if ! in_time_interval "$cur_min" "$start_min" "$end_min"; then
    cond_json tripped end_night \
      "outside night window ($cur_hhmm $WINDOW_TZ is not within $WINDOW_START-$WINDOW_END)" "$details"
    return 0
  fi
  if [ "$last_min" -ne "$end_min" ] && in_time_interval "$cur_min" "$last_min" "$end_min"; then
    cond_json tripped stop_dispatch \
      "past last-dispatch cut-off ($cur_hhmm >= $LAST_DISPATCH $WINDOW_TZ; draining until $WINDOW_END)" "$details"
    return 0
  fi
  cond_json ok continue "" "$details"
}

eval_claude_quota() {
  local qbin json rc=0 parsed
  if [ -n "${FM_NIGHT_QUOTA_BIN:-}" ]; then
    [ -x "$FM_NIGHT_QUOTA_BIN" ] || { cond_json unknown stop_dispatch "FM_NIGHT_QUOTA_BIN is not executable" '{}'; return 0; }
    qbin=$FM_NIGHT_QUOTA_BIN
  else
    qbin=$(type -P quota-axi 2>/dev/null) || { cond_json unknown stop_dispatch "quota-axi is not installed" '{}'; return 0; }
  fi
  json=$(fm_run_timed "$QUOTA_TIMEOUT" "$qbin" --provider claude --json --full --no-credential-refresh 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    cond_json unknown stop_dispatch "quota-axi timed out after ${QUOTA_TIMEOUT}s" '{}'
    return 0
  elif [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    cond_json unknown stop_dispatch "quota-axi read failed (exit $rc)" '{}'
    return 0
  fi
  if ! printf '%s\n' "$json" | fm_quota_json_valid; then
    cond_json unknown stop_dispatch "quota-axi returned an unexpected JSON schema" '{}'
    return 0
  fi
  # shellcheck disable=SC2016
  parsed=$(printf '%s\n' "$json" | jq -c \
    --argjson stop_all "$CLAUDE_STOP_ALL_PCT" \
    --argjson stop_claude "$CLAUDE_STOP_CLAUDE_PCT" \
    "$FM_QUOTA_ROW_JQ"'
    def rem:
      if (.percentRemaining | type) == "number" then .percentRemaining
      elif (.percentUsed | type) == "number" then (100 - .percentUsed)
      else null end
      | if . != null and . >= 0 and . <= 100 then . else null end;
    quota_row(.; "claude"; "") as $row
    | if ($row // null) == null then
        {status: "unknown", verdict_effect: "stop_dispatch", reason: "quota-axi snapshot has no claude provider row", details: {}}
      else
        ([ ($row.windows // [])[] | select(.id == "five_hour") | rem | select(. != null) ] | first // null) as $five
        | ([ ($row.windows // [])[] | select(.id == "seven_day") | rem | select(. != null) ] | first // null) as $week
        | ([ (if $five != null then {id: "five_hour", rem: $five} else empty end),
             (if $week != null then {id: "seven_day", rem: $week} else empty end) ]) as $avail
        | if ($avail | length) == 0 then
            {status: "unknown", verdict_effect: "stop_dispatch", reason: "quota-axi returned neither five_hour nor seven_day Claude window", details: {five_hour_remaining_pct: null, seven_day_remaining_pct: null}}
          else
            ($avail | min_by(.rem)) as $worst
            | {
                five_hour_remaining_pct: $five,
                seven_day_remaining_pct: $week,
                limiting_window: $worst.id,
                min_remaining_pct: $worst.rem,
                stop_claude_floor_pct: $stop_claude,
                stop_all_floor_pct: $stop_all
              } as $det
            | if $worst.rem < $stop_all then
                {status: "tripped", verdict_effect: "stop_dispatch", reason: "Claude \($worst.id) quota remaining (\($worst.rem)%) is below \($stop_all)% all-work floor", details: $det}
              elif $worst.rem < $stop_claude then
                {status: "tripped", verdict_effect: "stop_claude", reason: "Claude \($worst.id) quota remaining (\($worst.rem)%) is below \($stop_claude)% Claude-work floor", details: $det}
              else
                {status: "ok", verdict_effect: "continue", reason: "", details: $det}
              end
          end
      end
  ' 2>/dev/null) || parsed=""
  if [ -z "$parsed" ]; then
    cond_json unknown stop_dispatch "failed to parse quota-axi Claude windows" '{}'
    return 0
  fi
  printf '%s\n' "$parsed"
}

eval_github_api() {
  local gbin json rc=0 parsed
  if [ -n "${FM_NIGHT_GH_BIN:-}" ]; then
    [ -x "$FM_NIGHT_GH_BIN" ] || { cond_json unknown stop_dispatch "FM_NIGHT_GH_BIN is not executable" '{}'; return 0; }
    gbin=$FM_NIGHT_GH_BIN
  else
    gbin=$(type -P gh 2>/dev/null) || { cond_json unknown stop_dispatch "gh CLI is not installed" '{}'; return 0; }
  fi
  json=$(fm_run_timed "$GH_TIMEOUT" "$gbin" api rate_limit 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    cond_json unknown stop_dispatch "gh api rate_limit timed out after ${GH_TIMEOUT}s" '{}'
    return 0
  elif [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    cond_json unknown stop_dispatch "gh api rate_limit failed (exit $rc)" '{}'
    return 0
  fi
  # shellcheck disable=SC2016
  parsed=$(printf '%s\n' "$json" | jq -c --argjson floor "$GITHUB_API_FLOOR" '
    if (type == "object")
       and (.resources | type == "object")
       and (.resources.core | type == "object")
       and (.resources.core.remaining | type == "number" and . >= 0 and floor == .) then
      (.resources.core.remaining) as $rem
      | {
          remaining: $rem,
          limit: (.resources.core.limit // null),
          reset_epoch: (.resources.core.reset // null),
          floor: $floor
        } as $det
      | if $rem < $floor then
          {status: "tripped", verdict_effect: "stop_dispatch", reason: "GitHub core API remaining (\($rem)) is below floor (\($floor))", details: $det}
        else
          {status: "ok", verdict_effect: "continue", reason: "", details: $det}
        end
    else
      {status: "unknown", verdict_effect: "stop_dispatch", reason: "gh api rate_limit returned unexpected JSON shape", details: {}}
    end
  ' 2>/dev/null) || parsed=""
  if [ -z "$parsed" ]; then
    cond_json unknown stop_dispatch "gh api rate_limit returned invalid JSON" '{}'
    return 0
  fi
  printf '%s\n' "$parsed"
}

extract_terminal_status() {  # <file> -> prints "<epoch>\t<verb>" or empty
  local file=$1 line verb at m
  line=$(awk '
    /^(done|failed)([[:space:]]+\[[^]]+\])*:/ { last = $0 }
    END { if (last != "") print last }
  ' "$file" 2>/dev/null) || return 1
  [ -n "$line" ] || return 0
  verb=${line%%[: ]*}
  at=$(printf '%s\n' "$line" | sed -n 's/^[a-z]*[[:space:]].*\[at=\([0-9][0-9]*\)\].*/\1/p')
  if ! is_uint "$at"; then
    m=$(file_mtime "$file") || return 1
    at=$m
  fi
  printf '%s\t%s\n' "$at" "$verb"
}

eval_failure_streak() {  # <since_epoch>
  local since=$1 rows="" f id res at verb
  local -a candidates=()
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    candidates+=("$f")
  done
  if [ -d "$DATA" ]; then
    for f in "$DATA"/*/status.log "$DATA"/*/status.[0-9]*.log; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      candidates+=("$f")
    done
  fi
  for f in ${candidates[@]+"${candidates[@]}"}; do
    if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
      cond_json unknown stop_dispatch "status log $f is unreadable or unsafe" '{}'
      return 0
    fi
    case "$f" in
      "$STATE"/*.status)
        id=$(basename "$f" .status)
        ;;
      *)
        id=$(basename "$(dirname "$f")")
        ;;
    esac
    if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta" 2>/dev/null; then
      continue
    fi
    res=$(extract_terminal_status "$f") || {
      cond_json unknown stop_dispatch "could not read terminal status from $f" '{}'
      return 0
    }
    [ -n "$res" ] || continue
    at=${res%%	*}
    verb=${res#*	}
    if [ "$at" -ge "$since" ]; then
      rows="${rows}${at}	${id}	${verb}
"
    fi
  done
  # shellcheck disable=SC2016
  printf '%s' "$rows" | jq -Rsc --argjson limit "$FAILURE_STREAK_LIMIT" --argjson since "$since" '
    split("\n")
    | map(select(. != "") | split("\t") | {at: (.[0] | tonumber), id: .[1], verb: .[2]})
    | group_by(.id)
    | map(max_by(.at))
    | sort_by([.at, .id])
    | . as $all
    | (reduce ($all | reverse)[] as $item ({streak: 0, ids: [], stopped: false};
        if .stopped then .
        elif $item.verb == "failed" then {streak: (.streak + 1), ids: ([ $item.id ] + .ids), stopped: false}
        else .stopped = true end)) as $res
    | {
        streak: $res.streak,
        limit: $limit,
        since_epoch: $since,
        failed_tasks: $res.ids,
        total_completed: ($all | length)
      } as $det
    | if $res.streak >= $limit then
        {status: "tripped", verdict_effect: "stop_dispatch", reason: "failure streak of \($res.streak) consecutive failed night tickets (\($res.ids | join(", ")))", details: $det}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det}
      end
  '
}

eval_dev_health() {  # <since_epoch>
  local since=$1 f failed_json="[]" count=0
  if ! resolve_ledger_dir; then
    cond_json unknown stop_dispatch "$LEDGER_DIR_ERROR" '{}'
    return 0
  fi
  if [ ! -e "$LEDGER_DIR" ] && [ ! -L "$LEDGER_DIR" ]; then
    cond_json ok continue "" '{"failed_prs":[],"checked_ledgers":0}'
    return 0
  fi
  if [ -L "$LEDGER_DIR" ] || [ ! -d "$LEDGER_DIR" ] || [ ! -r "$LEDGER_DIR" ]; then
    cond_json unknown stop_dispatch "review ledger directory $LEDGER_DIR is unreadable or unsafe" '{}'
    return 0
  fi
  for f in "$LEDGER_DIR"/*.json; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
      cond_json unknown stop_dispatch "review ledger $f is unreadable or unsafe" '{}'
      return 0
    fi
    if ! jq -e '.schema == "firstmate-pr-review-ledger.v1" and (.url | type == "string") and (.generations | type == "array" and length > 0)' "$f" >/dev/null 2>&1; then
      cond_json unknown stop_dispatch "review ledger $(basename "$f") is malformed JSON" '{}'
      return 0
    fi
    count=$((count + 1))
    local item
    # shellcheck disable=SC2016
    item=$(jq -c --argjson since "$since" '
      (.generations[-1].post_merge_verifications // []) as $pmv
      | if ($pmv | length) == 0 then empty
        else
          ($pmv[-1]) as $last
          | if (($last.recorded_epoch // $since) >= $since)
               and (($last.outcome // "") == "failed" or ($last.ready_for_qa // "") == "blocked") then
              {url: .url, head: .current_head, outcome: ($last.outcome // "failed"), recorded_epoch: ($last.recorded_epoch // null)}
            else empty end
        end
    ' "$f" 2>/dev/null) || {
      cond_json unknown stop_dispatch "failed to inspect review ledger $(basename "$f")" '{}'
      return 0
    }
    if [ -n "$item" ]; then
      failed_json=$(printf '%s\n' "$failed_json" | jq -c --argjson item "$item" '. + [$item]')
    fi
  done
  # shellcheck disable=SC2016
  printf '%s\n' "$failed_json" | jq -c --argjson checked "$count" '
    {failed_prs: ., checked_ledgers: $checked} as $det
    | if length > 0 then
        {status: "tripped", verdict_effect: "stop_dispatch", reason: "failed post-merge check recorded in review ledger for \([.[].url] | join(", "))", details: $det}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det}
      end
  '
}

pr_url_ledger_path() {  # <pr-url> -> prints ledger path if GitHub PR URL
  local url=$1 rest owner repo num
  case "$url" in
    https://github.com/*/*/pull/[0-9]*)
      rest=${url#https://github.com/}
      owner=${rest%%/*}
      rest=${rest#*/}
      repo=${rest%%/*}
      num=${rest##*/}
      num=${num%%[/?#]*}
      printf '%s/github--%s--%s--%s.json\n' "$LEDGER_DIR" "$owner" "$repo" "$num"
      return 0
      ;;
  esac
  return 1
}

eval_check_machine() {
  local meta id kind pr sf done_line ledger_path waiting_json="[]"
  if ! resolve_ledger_dir; then
    cond_json unknown stop_dispatch "$LEDGER_DIR_ERROR" '{}'
    return 0
  fi
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if [ -L "$meta" ] || [ ! -f "$meta" ] || [ ! -r "$meta" ]; then
      cond_json unknown stop_dispatch "task metadata $meta is unreadable or unsafe" '{}'
      return 0
    fi
    kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | head -1)
    case "$kind" in secondmate|scout) continue ;; esac
    pr=$(sed -n 's/^pr=//p' "$meta" 2>/dev/null | head -1)
    [ -n "$pr" ] || continue
    id=$(basename "$meta" .meta)
    # Skip PRs already merged or whose poll was retired
    if [ -f "$STATE/$id.pr-poll-merge-notified" ] || [ -f "$STATE/$id.pr-poll-retirement" ]; then
      continue
    fi
    # Check status file if present: a "checks green" done line means CI already passed
    sf="$STATE/$id.status"
    if [ -e "$sf" ] || [ -L "$sf" ]; then
      if [ -L "$sf" ] || [ ! -f "$sf" ] || [ ! -r "$sf" ]; then
        cond_json unknown stop_dispatch "status file $sf is unreadable or unsafe" '{}'
        return 0
      fi
      done_line=$(awk '/^done([[:space:]]+\[[^]]+\])*:/ { last = $0 } END { if (last != "") print last }' "$sf" 2>/dev/null)
      case "$done_line" in
        *'checks green'*) continue ;;
      esac
    fi
    # Check review ledger if one exists for this PR
    if ledger_path=$(pr_url_ledger_path "$pr") && { [ -e "$ledger_path" ] || [ -L "$ledger_path" ]; }; then
      if [ -L "$ledger_path" ] || [ ! -f "$ledger_path" ] || [ ! -r "$ledger_path" ]; then
        cond_json unknown stop_dispatch "review ledger $ledger_path is unreadable or unsafe" '{}'
        return 0
      fi
      local ledger_state
      ledger_state=$(jq -r '
        if .schema != "firstmate-pr-review-ledger.v1" or (.generations | type != "array" or length == 0) then "invalid"
        elif (.generations[-1].merge_decision.decision // "") == "merge" then "done"
        elif ((.generations[-1].checkpoints // []) | length) > 0
             and (((.generations[-1].checkpoints[-1].checks // []) | length) > 0)
             and (all((.generations[-1].checkpoints[-1].checks // [])[]; .status == "completed" and .conclusion == "success")) then "done"
        else "waiting" end
      ' "$ledger_path" 2>/dev/null) || ledger_state="invalid"
      case "$ledger_state" in
        invalid)
          cond_json unknown stop_dispatch "review ledger $(basename "$ledger_path") is malformed" '{}'
          return 0
          ;;
        done) continue ;;
      esac
    fi
    waiting_json=$(printf '%s\n' "$waiting_json" | jq -c --arg id "$id" --arg pr "$pr" '. + [{task: $id, pr: $pr}]')
  done
  # shellcheck disable=SC2016
  printf '%s\n' "$waiting_json" | jq -c --argjson limit "$CHECK_QUEUE_LIMIT" '
    {waiting_count: length, limit: $limit, waiting_prs: .} as $det
    | if length >= $limit then
        {status: "tripped", verdict_effect: "stop_dispatch", reason: "\(length) finished PRs waiting for a check slot (limit \($limit)): \([.[].task] | join(", "))", details: $det}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det}
      end
  '
}

eval_validation_cap() {  # <since_epoch>
  local since=$1 f runs_json="[]"
  if ! resolve_ledger_dir; then
    cond_json unknown stop_dispatch "$LEDGER_DIR_ERROR" '{}'
    return 0
  fi
  if [ -e "$LEDGER_DIR" ] || [ -L "$LEDGER_DIR" ]; then
    if [ -L "$LEDGER_DIR" ] || [ ! -d "$LEDGER_DIR" ] || [ ! -r "$LEDGER_DIR" ]; then
      cond_json unknown stop_dispatch "review ledger directory $LEDGER_DIR is unreadable or unsafe" '{}'
      return 0
    fi
    for f in "$LEDGER_DIR"/*.json; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
        cond_json unknown stop_dispatch "review ledger $f is unreadable or unsafe" '{}'
        return 0
      fi
      if ! jq -e '.schema == "firstmate-pr-review-ledger.v1" and (.url | type == "string") and (.generations | type == "array" and length > 0)' "$f" >/dev/null 2>&1; then
        cond_json unknown stop_dispatch "review ledger $(basename "$f") is malformed JSON" '{}'
        return 0
      fi
      local rows line u h k a ce ep key
      rows=$(jq -r '
        .url as $u
        | .generations[]
        | select((.risk.level // "") == "high")
        | (.created_epoch // 0) as $ce
        | (.attestations // [])[]
        | [$u, (.head // ""), (.kind // ""), (.at // ""), ($ce | tostring)] | @tsv
      ' "$f" 2>/dev/null) || {
        cond_json unknown stop_dispatch "failed to read attestations from $(basename "$f")" '{}'
        return 0
      }
      while IFS=$'\t' read -r u h k a ce; do
        [ -n "$u" ] || continue
        if [ -n "$a" ] && ep=$(iso_to_epoch "$a"); then
          :
        elif is_uint "$ce"; then
          ep=$ce
        else
          continue
        fi
        if [ "$ep" -ge "$since" ]; then
          key="ledger:${u}:${h}:${k}:${a}"
          runs_json=$(printf '%s\n' "$runs_json" | jq -c --arg key "$key" --arg src "review-ledger" --argjson ep "$ep" '
            if any(.[]; .key == $key) then . else . + [{key: $key, source: $src, epoch: $ep}] end
          ')
        fi
      done <<EOF
$rows
EOF
    done
  fi
  if [ -f "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ] && [ -r "$ACTIVE_FILE" ]; then
    local rec_rows rid rep key
    rec_rows=$(jq -r '
      if .schema == "fm-night-active.v1" then
        (.validations // [])[] | [(.id // ""), ((.recorded_epoch // 0) | tostring)] | @tsv
      else empty end
    ' "$ACTIVE_FILE" 2>/dev/null) || rec_rows=""
    while IFS=$'\t' read -r rid rep; do
      [ -n "$rid" ] || continue
      is_uint "$rep" || continue
      if [ "$rep" -ge "$since" ]; then
        key="recorded:${rid}"
        runs_json=$(printf '%s\n' "$runs_json" | jq -c --arg key "$key" --arg src "night-active" --argjson ep "$rep" '
          if any(.[]; .key == $key) then . else . + [{key: $key, source: $src, epoch: $ep}] end
        ')
      fi
    done <<EOF
$rec_rows
EOF
  fi
  # shellcheck disable=SC2016
  printf '%s\n' "$runs_json" | jq -c --argjson cap "$VALIDATION_CAP" --argjson since "$since" '
    {count: length, cap: $cap, since_epoch: $since, runs: .} as $det
    | if length >= $cap then
        {status: "tripped", verdict_effect: "stop_claude", reason: "high-stakes validation cap reached (\(length) of \($cap) runs tonight)", details: $det}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det}
      end
  '
}

eval_supervision_stall() {  # <now>
  local now=$1 wq="$STATE/.wake-queue" hf="$STATE/.supervision-host-health"
  local limit_s=$((STALL_MINUTES * 60))
  local oldest_epoch="" wake_age=0 wake_count=0 wake_stalled=0
  local latch_stalled=0 latch_cooldown=0 latch_retry=0
  local stall_since=null reasons=""

  if [ -e "$wq" ] || [ -L "$wq" ]; then
    if [ -L "$wq" ] || [ ! -f "$wq" ] || [ ! -r "$wq" ]; then
      cond_json unknown stop_dispatch "wake queue $wq is unreadable or unsafe" '{}'
      return 0
    fi
    if [ -s "$wq" ]; then
      local parsed_wq
      parsed_wq=$(awk -F '\t' '
        /^[[:space:]]*$/ { next }
        {
          if (NF < 5 || $1 !~ /^[0-9]+$/) { bad = 1; exit }
          c++
          if (min == "" || ($1 + 0) < (min + 0)) min = $1
        }
        END {
          if (bad) { print "BAD"; exit 1 }
          if (c > 0) printf "%s\t%d\n", min, c
        }
      ' "$wq" 2>/dev/null) || {
        cond_json unknown stop_dispatch "wake queue $wq contains malformed rows" '{}'
        return 0
      }
      if [ -n "$parsed_wq" ]; then
        oldest_epoch=${parsed_wq%%	*}
        wake_count=${parsed_wq#*	}
        if [ "$now" -gt "$oldest_epoch" ]; then
          wake_age=$((now - oldest_epoch))
        else
          wake_age=0
        fi
        if [ "$wake_age" -gt "$limit_s" ]; then
          wake_stalled=1
          stall_since=$oldest_epoch
          reasons="oldest unacknowledged wake is ${wake_age}s old (limit ${limit_s}s)"
        fi
      fi
    fi
  fi

  if [ -e "$hf" ] || [ -L "$hf" ]; then
    if [ -L "$hf" ] || [ ! -f "$hf" ] || [ ! -r "$hf" ]; then
      cond_json unknown stop_dispatch "supervision-host health file $hf is unreadable or unsafe" '{}'
      return 0
    fi
    local cd_val ra_val
    cd_val=$(sed -n 's/^cooldown=//p' "$hf" 2>/dev/null | head -1)
    ra_val=$(sed -n 's/^retry_after=//p' "$hf" 2>/dev/null | head -1)
    if is_uint "$cd_val" && is_uint "$ra_val" && [ "$cd_val" -gt 0 ] && [ "$ra_val" -gt "$now" ]; then
      latch_stalled=1
      latch_cooldown=$cd_val
      latch_retry=$ra_val
      if [ "$stall_since" = "null" ]; then
        local est=$((ra_val - cd_val))
        [ "$est" -ge 0 ] || est=0
        stall_since=$est
      fi
      local lreason="supervision-host engine latched (cooldown ${cd_val}s, retry_after ${ra_val})"
      reasons="${reasons:+$reasons; }$lreason"
    fi
  fi

  local details
  details=$(jq -cn \
    --arg oldest "$oldest_epoch" \
    --argjson wake_age "$wake_age" \
    --argjson wake_count "$wake_count" \
    --argjson limit_s "$limit_s" \
    --argjson latch_stalled "$latch_stalled" \
    --argjson latch_cooldown "$latch_cooldown" \
    --argjson latch_retry "$latch_retry" \
    --argjson stall_since "$stall_since" \
    '{
      oldest_wake_epoch: (if $oldest == "" then null else ($oldest | tonumber) end),
      oldest_wake_age_seconds: $wake_age,
      queued_wakes: $wake_count,
      limit_seconds: $limit_s,
      engine_latched: ($latch_stalled == 1),
      engine_cooldown_seconds: $latch_cooldown,
      engine_retry_after_epoch: $latch_retry,
      stall_since_epoch: $stall_since
    }')
  if [ "$wake_stalled" -eq 1 ] || [ "$latch_stalled" -eq 1 ]; then
    cond_json tripped stop_dispatch "supervision stall: $reasons" "$details"
  else
    cond_json ok continue "" "$details"
  fi
}

eval_hc_core() {  # <now> <since_epoch>
  local now=$1 since=$2 has_base=0 base_json=null cur_json
  if [ -f "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ] && [ -r "$ACTIVE_FILE" ]; then
    base_json=$(jq -c 'if .schema == "fm-night-active.v1" and (.hc_baseline | type == "object") then .hc_baseline else null end' "$ACTIVE_FILE" 2>/dev/null) || base_json=null
    [ "$base_json" != "null" ] && has_base=1
  fi
  if ! hc_backend_configured && [ "$has_base" -eq 0 ]; then
    cond_json not_applicable continue "" '{}'
    return 0
  fi
  if ! cur_json=$(read_hc_status_json "$now"); then
    cond_json unknown stop_dispatch "herdr-core server status could not be read" '{}'
    return 0
  fi
  # shellcheck disable=SC2016
  jq -cn \
    --argjson cur "$cur_json" \
    --argjson base "$base_json" \
    --argjson since "$since" '
    (if $base != null and ($base.pid | type == "number") and $cur.pid != $base.pid then
       "hc core pid changed (\($base.pid) -> \($cur.pid))"
     elif $base != null and (($base.holder_instance // "") != "") and (($cur.holder_instance // "") != "") and $cur.holder_instance != $base.holder_instance then
       "hc core holder instance changed (\($base.holder_instance) -> \($cur.holder_instance))"
     elif $base != null and (($base.core_id // "") != "") and (($cur.core_id // "") != "") and $cur.core_id != $base.core_id then
       "hc core id changed (\($base.core_id) -> \($cur.core_id))"
     elif $cur.started_epoch > ($since + 5) then
       "hc core started after night began (started_epoch \($cur.started_epoch) > night_start \($since), uptime \($cur.uptime_ms)ms)"
     else "" end) as $restart_reason
    | {baseline: $base, current: $cur} as $det
    | if $restart_reason != "" then
        {status: "tripped", verdict_effect: "end_night", reason: "hc core restarted during the night: \($restart_reason)", details: $det}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det}
      end
  '
}

eval_host_load() {  # <now>
  local now=$1 os load1="" prev_since=null
  os=$(uname -s 2>/dev/null) || os=unknown
  if [ -n "${FM_PROC_ROOT_OVERRIDE:-}" ] || [ "$os" != Darwin ]; then
    if [ -f "$PROC_ROOT/loadavg" ] && [ -r "$PROC_ROOT/loadavg" ]; then
      load1=$(awk '{print $1}' "$PROC_ROOT/loadavg" 2>/dev/null) || load1=""
    fi
  else
    load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}') || load1=""
  fi
  if ! is_num "$load1"; then
    cond_json unknown stop_dispatch "could not read 1-minute host load average" '{}'
    return 0
  fi
  if [ -f "$VERDICT_FILE" ] && [ ! -L "$VERDICT_FILE" ] && [ -r "$VERDICT_FILE" ]; then
    prev_since=$(jq -c --argjson now "$now" '
      (.conditions.host_load.details.high_load_since_epoch // null)
      | if (type == "number" and . <= $now) then . else null end
    ' "$VERDICT_FILE" 2>/dev/null) || prev_since=null
    [ -n "$prev_since" ] || prev_since=null
  fi
  # shellcheck disable=SC2016
  jq -cn \
    --arg load1 "$load1" \
    --arg thresh "$HIGH_LOAD_THRESHOLD" \
    --argjson mins "$HIGH_LOAD_MINUTES" \
    --argjson now "$now" \
    --argjson prev_since "$prev_since" '
    ($load1 | tonumber) as $l
    | ($thresh | tonumber) as $t
    | ($mins * 60) as $dur_limit
    | if $l >= $t then
        ($prev_since // $now) as $since
        | ($now - $since) as $elapsed
        | {load1: $l, threshold: $t, limit_seconds: $dur_limit, high_load_since_epoch: $since, elapsed_seconds: $elapsed} as $det
        | if $elapsed >= $dur_limit then
            {status: "tripped", verdict_effect: "stop_dispatch", reason: "host 1-minute load (\($l)) stayed >= \($t) for \($elapsed)s (limit \($dur_limit)s)", details: $det}
          else
            {status: "ok", verdict_effect: "continue", reason: "", details: $det}
          end
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: {load1: $l, threshold: $t, limit_seconds: $dur_limit, high_load_since_epoch: null, elapsed_seconds: 0}}
      end
  '
}

# --- Durable stop record (single owner path) --------------------------------
write_stop_record() {  # <verdict_json> <now> <iso>
  local verdict_json=$1 now=$2 iso=$3
  local first_epoch=$now first_at=$iso prev_stall=null doc
  if [ -f "$STOP_FILE" ] && [ ! -L "$STOP_FILE" ] && [ -r "$STOP_FILE" ]; then
    local pe pa ps
    pe=$(jq -r 'if .schema == "fm-night-stop.v1" and (.first_tripped_epoch | type == "number") then .first_tripped_epoch else empty end' "$STOP_FILE" 2>/dev/null) || pe=""
    pa=$(jq -r 'if .schema == "fm-night-stop.v1" and (.first_tripped_at | type == "string") then .first_tripped_at else empty end' "$STOP_FILE" 2>/dev/null) || pa=""
    ps=$(jq -c 'if .schema == "fm-night-stop.v1" and (.stall_since_epoch | type == "number") then .stall_since_epoch else null end' "$STOP_FILE" 2>/dev/null) || ps=null
    [ -z "$pe" ] || first_epoch=$pe
    [ -z "$pa" ] || first_at=$pa
    prev_stall=${ps:-null}
  fi
  doc=$(printf '%s\n' "$verdict_json" | jq \
    --argjson first_epoch "$first_epoch" \
    --arg first_at "$first_at" \
    --argjson now "$now" \
    --arg iso "$iso" \
    --argjson prev_stall "$prev_stall" '
    (.conditions.supervision_stall.details.stall_since_epoch // $prev_stall) as $stall_since
    | {
        schema: "fm-night-stop.v1",
        first_tripped_epoch: $first_epoch,
        first_tripped_at: $first_at,
        last_checked_epoch: $now,
        last_checked_at: $iso,
        night_started_epoch: .night_started_epoch,
        verdict: .verdict,
        verdict_label: .verdict_label,
        allow: .allow,
        tripped: .tripped,
        reasons: .reasons,
        stall_since_epoch: $stall_since,
        core_restarted: (.conditions.hc_core.status == "tripped"),
        reserve_flag: .reserve_flag
      }
  ') || return 1
  atomic_write_json "$STOP_FILE" "$doc"
}

render_human_verdict() {  # <verdict_json_file>
  jq -r '
    "night-check: verdict=\(.verdict) (\(.verdict_label)) dispatch=\(.allow.dispatch) claude=\(.allow.claude) merge=\(.allow.merge) validation=\(.allow.validation) two_hour_default=\(.allow.two_hour_default)",
    (.tripped[] | "  - \(.condition) (\(.status) -> \(.verdict_effect)): \(.reason)")
  ' "$1"
}

# --- Main check flow --------------------------------------------------------
cmd_check() {
  local want_json=0
  if [ "${1:-}" = "--json" ]; then
    want_json=1
    shift
  fi
  [ "$#" -eq 0 ] || die_usage "unexpected arguments to check"
  type -P jq >/dev/null 2>&1 || die_usage "jq is required"
  load_check_libs

  local now iso night_active=false night_started=null active_bad=0
  now=$(now_epoch)
  iso=$(epoch_to_iso "$now")

  parse_night_config || true

  if [ -e "$ACTIVE_FILE" ] || [ -L "$ACTIVE_FILE" ]; then
    if [ -f "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ] && [ -r "$ACTIVE_FILE" ] \
      && jq -e '.schema == "fm-night-active.v1" and (.started_epoch | type == "number")' "$ACTIVE_FILE" >/dev/null 2>&1; then
      night_active=true
      night_started=$(jq -r '.started_epoch' "$ACTIVE_FILE")
    else
      night_active=true
      active_bad=1
    fi
  fi

  local since_epoch
  if is_uint "$night_started"; then
    since_epoch=$night_started
  else
    since_epoch=$((now - 43200))
    [ "$since_epoch" -ge 0 ] || since_epoch=0
  fi

  local c_window c_quota c_gh c_streak c_dev c_cm c_val c_stall c_hc c_load
  c_window=$(eval_night_window "$now" "$active_bad")
  c_quota=$(eval_claude_quota)
  c_gh=$(eval_github_api)
  c_streak=$(eval_failure_streak "$since_epoch")
  c_dev=$(eval_dev_health "$since_epoch")
  c_cm=$(eval_check_machine)
  c_val=$(eval_validation_cap "$since_epoch")
  c_stall=$(eval_supervision_stall "$now")
  c_hc=$(eval_hc_core "$now" "$since_epoch")
  c_load=$(eval_host_load "$now")

  local rf_configured=false rf_path="" rf_set=false
  if rf_path=$(first_lane_reserve_flag); then
    rf_configured=true
  else
    rf_path=""
  fi

  local verdict_doc
  verdict_doc=$(jq -n \
    --argjson now "$now" \
    --arg iso "$iso" \
    --argjson night_active "$night_active" \
    --argjson night_started "$night_started" \
    --argjson c_window "$c_window" \
    --argjson c_quota "$c_quota" \
    --argjson c_gh "$c_gh" \
    --argjson c_streak "$c_streak" \
    --argjson c_dev "$c_dev" \
    --argjson c_cm "$c_cm" \
    --argjson c_val "$c_val" \
    --argjson c_stall "$c_stall" \
    --argjson c_hc "$c_hc" \
    --argjson c_load "$c_load" \
    --argjson rf_configured "$rf_configured" \
    --arg rf_path "$rf_path" \
    '
    def rank:
      if . == "end_night" then 3
      elif . == "stop_dispatch" then 2
      elif . == "stop_claude" then 1
      else 0 end;
    def verdict_label:
      if . == "end_night" then "end the night"
      elif . == "stop_dispatch" then "stop new dispatch"
      elif . == "stop_claude" then "stop new Claude work"
      else "continue" end;
    {
      night_window: $c_window,
      claude_quota: $c_quota,
      github_api: $c_gh,
      failure_streak: $c_streak,
      dev_health: $c_dev,
      check_machine: $c_cm,
      validation_cap: $c_val,
      supervision_stall: $c_stall,
      hc_core: $c_hc,
      host_load: $c_load
    } as $conds
    | [ $conds | to_entries[] | select(.value.status == "tripped" or .value.status == "unknown")
        | {condition: .key, status: .value.status, verdict_effect: .value.verdict_effect, reason: .value.reason} ] as $tripped
    | (if ($tripped | length) == 0 then "continue"
       else ($tripped | max_by(.verdict_effect | rank) | .verdict_effect) end) as $verdict
    | ($verdict == "continue" or $verdict == "stop_claude") as $allow_dispatch
    | ($verdict == "continue") as $allow_claude
    | ($verdict != "end_night"
       and $conds.dev_health.status == "ok"
       and $conds.supervision_stall.status == "ok"
       and $conds.hc_core.status != "tripped"
       and $conds.hc_core.status != "unknown") as $allow_merge
    | ($verdict == "continue") as $allow_validation
    | (($verdict == "continue" or $verdict == "stop_claude")
       and $conds.dev_health.status == "ok"
       and $conds.supervision_stall.status == "ok"
       and $conds.hc_core.status != "tripped"
       and $conds.hc_core.status != "unknown") as $allow_default
    | {
        schema: "fm-night-verdict.v1",
        checked_epoch: $now,
        checked_at: $iso,
        night_active: $night_active,
        night_started_epoch: $night_started,
        verdict: $verdict,
        verdict_label: ($verdict | verdict_label),
        allow: {
          dispatch: $allow_dispatch,
          claude: $allow_claude,
          merge: $allow_merge,
          validation: $allow_validation,
          two_hour_default: $allow_default
        },
        tripped: $tripped,
        reasons: [$tripped[].reason],
        conditions: $conds,
        reserve_flag: {
          configured: $rf_configured,
          path: (if $rf_path == "" then null else $rf_path end),
          set_by_check: false
        },
        stop_record_path: null
      }
  ') || die "could not assemble verdict document"

  local final_verdict allow_dispatch reasons_summary
  final_verdict=$(printf '%s\n' "$verdict_doc" | jq -r '.verdict')
  allow_dispatch=$(printf '%s\n' "$verdict_doc" | jq -r '.allow.dispatch')
  reasons_summary=$(printf '%s\n' "$verdict_doc" | jq -r '.reasons | join("; ")')

  if [ "$allow_dispatch" = "false" ] && [ "$rf_configured" = "true" ] && [ -n "$rf_path" ]; then
    if set_lane_reserve_flag "$rf_path" "$final_verdict" "$iso" "$reasons_summary"; then
      rf_set=true
    else
      printf 'fm-night-check: warning: could not write reserve-flag at %s\n' "$rf_path" >&2
    fi
  fi

  local stop_path_json="null"
  if [ "$final_verdict" != "continue" ]; then
    stop_path_json=$(jq -cn --arg p "$STOP_FILE" '$p')
  fi

  verdict_doc=$(printf '%s\n' "$verdict_doc" | jq \
    --argjson rf_set "$rf_set" \
    --argjson stop_path "$stop_path_json" \
    '.reserve_flag.set_by_check = $rf_set | .stop_record_path = $stop_path')

  if [ "$final_verdict" != "continue" ]; then
    write_stop_record "$verdict_doc" "$now" "$iso" || die "could not write $STOP_FILE"
  fi
  atomic_write_json "$VERDICT_FILE" "$verdict_doc" || die "could not write $VERDICT_FILE"

  if [ "$want_json" -eq 1 ]; then
    printf '%s\n' "$verdict_doc"
  else
    render_human_verdict "$VERDICT_FILE"
  fi
}

# --- CLI dispatch -----------------------------------------------------------
cmd=${1:-check}
case "$cmd" in
  -h|--help)
    usage
    exit 0
    ;;
  check)
    [ "$#" -eq 0 ] || shift
    cmd_check "$@"
    ;;
  --json)
    cmd_check --json
    ;;
  verdict)
    shift
    cmd_verdict "$@"
    ;;
  start)
    shift
    [ "$#" -eq 0 ] || die_usage "start takes no arguments"
    cmd_start
    ;;
  end)
    shift
    [ "$#" -eq 0 ] || die_usage "end takes no arguments"
    cmd_end
    ;;
  record-validation)
    shift
    cmd_record_validation "$@"
    ;;
  hc-guard)
    shift
    [ "$#" -eq 0 ] || die_usage "hc-guard takes no arguments"
    cmd_hc_guard
    ;;
  *)
    die_usage "unknown subcommand '$cmd'"
    ;;
esac
