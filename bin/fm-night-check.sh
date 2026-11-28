#!/usr/bin/env bash
# fm-night-check.sh - overnight stop-and-health check and herdr-core (hc)
# night guard.
#
# Single owner of the overnight stop-condition evaluation, its durable night
# records under state/, its machine-readable verdict document for the morning
# board (P3) and two-hour default gate (P2), and the hc night guard
# (`hc-guard`) that refuses herdr-core installs (`bin/fm-install-hc.sh`) while
# a night is active. A direct upstream `hc` / `herdr-core` stop is outside what
# this repository can intercept.
#
# Usage:
#   fm-night-check.sh [check] [--json]
#   fm-night-check.sh verdict [--json]
#   fm-night-check.sh start
#   fm-night-check.sh end
#   fm-night-check.sh hc-guard
#   fm-night-check.sh --help
#
# Verdicts (ordered from least to most severe; the most severe tripped,
# unknown, or latched condition wins):
#   continue        All evaluated conditions are healthy; dispatch, Claude work,
#                   merges, validations, and (when a night is active) two-hour
#                   defaults may proceed.
#   stop_validation ("stop new validations") Start no new high-stakes
#                   validation run (validation cap reached); dispatch and
#                   Claude work may still proceed.
#   stop_claude     ("stop new Claude work") Stop new Claude-harness work and
#                   validations (Claude 5h or weekly quota < 25%); non-Claude
#                   builders may still dispatch.
#   stop_dispatch   ("stop new dispatch") Admit no new work at all (e.g. past
#                   last-dispatch cut-off, Claude quota < 12%, GitHub core API
#                   < 1000, failure streak >= 3, failed latest post-merge check,
#                   >= 2 distinct PR heads waiting for CI/check admission,
#                   supervision stall, sustained high host load, or ANY
#                   unreadable/unknown source).
#   end_night       ("end the night") The night is over (outside the configured
#                   night window or hc core restarted); disallows dispatch,
#                   Claude work, merges, validations, and two-hour defaults.
#
# Stop-by-default verdict architecture (`evaluate_night_verdict`):
#   Every condition reader returns a typed result `{status, verdict_effect,
#   reason, details, proof}` where `proof` carries `{present, readable,
#   observed_epoch, max_age_seconds, target_scope}`. One single function,
#   `evaluate_night_verdict`, owns all allow/stop decisions with STOP as the
#   default: work is allowed only when every required input is proven `ok`
#   (or `not_applicable` for `hc_core` on a proven non-hc backend), present,
#   readable, within its maximum allowed age, and on its target scope/branch.
#   Any missing, unreadable, malformed, stale, wrong-branch, or unknown input
#   overrides to `unknown` (`stop_dispatch`) and blocks dispatch, Claude work,
#   merges, validations, and two-hour defaults.
#
# Required inputs, allowed ages, and scopes (enforced by `evaluate_night_verdict`):
#   night_window      max age: 60s (live)    scope: configured IANA timezone
#   claude_quota      max age: 900s (15m)    scope: Claude five_hour + seven_day
#   github_api        max age: 60s (live)    scope: GitHub core hourly limit
#   failure_streak    max age: 60s (live)    scope: night kind=ship (live + archive)
#   dev_health        max age: 60s (live)    scope: per-(repo, target_branch), any age
#   check_machine     max age: 1800s (30m)   scope: per confirmed 40-hex PR head
#   validation_cap    max age: 60s (live)    scope: per-(url, head) high-risk gen
#   supervision_stall max age: 60s (live)    scope: home supervision engine key
#   hc_core           max age: 43200s (12h)  scope: saved backend + hc target
#   host_load         max age: 60s (live)    scope: host 1-minute loadavg
#   night_stop_record max age: same night    scope: active night_started_epoch
#   These ages are fixed constants with no environment override
#   (LIVE_INPUT_MAX_AGE=60, QUOTA_MAX_AGE=900, CHECK_EVIDENCE_MAX_AGE=1800,
#   HC_TARGET_MAX_AGE=43200), as is the night ship status startup grace
#   (SHIP_STATUS_GRACE=900).
#
# Condition sources and boundaries:
#   night_window      Local time in configured IANA timezone against
#                     [window-start, last-dispatch, window-end].
#   claude_quota      Requires one valid, current (fresh, non-stale) reading
#                     for BOTH five_hour and seven_day from `quota-axi`. Strict
#                     `<` comparison against the floors (defaults 25 and 12;
#                     config may only raise them, never lower below 25/12).
#   github_api        `gh api rate_limit` `.resources.core.remaining < floor`.
#   failure_streak    Limited to `kind=ship` tasks spawned inside the night
#                     window across live `state/` records and retired status
#                     archives under `data/<id>/status*.log` (requires
#                     `config/status-archive` enabled for night runs;
#                     deduplicated by task and `spawn_gen`, excluding live
#                     scouts, secondmates, and pre-night tasks). A retired
#                     task's kind comes from its own `data/<id>/brief.md`: the
#                     generated `Delivery contract: mode=` line marks a ship,
#                     and only a positively identified scout, landing-crew, or
#                     secondmate brief is excluded; a task whose kind cannot be
#                     determined (brief gone, unreadable, or unmarked) counts
#                     as a ship. A night ship with no status line yet counts as
#                     no outcome for SHIP_STATUS_GRACE seconds after its spawn;
#                     after that, missing both live and archived status reports
#                     `unknown`.
#   dev_health        Latest valid passed or failed post-merge verification
#                     record per `(repo, target_branch)` across review ledgers,
#                     at any age and with no night-start filter, so a failure
#                     recorded before the night stays red and a later passing
#                     record on the same target branch clears it. A merge
#                     decision whose `verified_epoch` falls inside the night
#                     window is a night merge only once the forge confirms it
#                     (its own post-merge record, which `bin/fm-pr-review.sh`
#                     writes only after a forge-confirmed merge, or
#                     `gh pr view --json state` reporting `MERGED`; a decision
#                     whose PR never merged is not a night merge, and a failed
#                     forge read reports `unknown`). Each night merge needs its
#                     own dated post-merge record (passed, failed, or
#                     not-applicable), or a passed/failed record on its forge
#                     target branch, recorded at or after its decision;
#                     otherwise `unknown`, so no next merge happens before the
#                     previous one is verified.
#                     New records require and carry
#                     a forge-confirmed `base_ref` written by
#                     `bin/fm-pr-review.sh post-merge`; valid older records
#                     without it resolve `baseRefName` via a bounded
#                     `gh pr view --json baseRefName`, only for red records,
#                     for passed records in a repo with an equal or older red
#                     record, or for repos with a confirmed night merge
#                     (failure yields `unknown` and is retried on the next
#                     check); each successful lookup
#                     is published to `state/night-pr-base-refs.json`, so the
#                     one-call-ever promise holds after a successful cache
#                     publish (cache publish failures are surfaced as verdict
#                     warnings without hiding the verified live result).
#                     Malformed or undated records report `unknown`.
#                     Not-applicable records neither clear nor set red.
#   check_machine     Counts distinct current PR heads whose `fm-crew-state.sh`
#                     current state is `paused` declaring a wait for CI or
#                     check-slot admission. Excludes active/working tasks and
#                     any PR whose current head has fresh, head-matched
#                     evidence of actively running checks (`IN_PROGRESS` /
#                     `RUNNING`) or completed required checks (`status ==
#                     "COMPLETED"` with `conclusion == "pass"` or `"skipping"`,
#                     matching `bin/fm-pr-review.sh`), or a head-verified merge
#                     decision. A stale or older-head checkpoint never excludes
#                     a wait: the task counts as waiting, the conservative
#                     choice that only stops new builders. A successful
#                     `state: unknown` crew-state reply, unconfirmed head, or
#                     malformed check status reports `unknown`
#                     (`stop_dispatch`) and never shrinks the wait count.
#   validation_cap    Counts high-stakes PRs whose validated current
#                     review-ledger generation was created during the night
#                     (`risk.level == "high"` and integer `created_epoch >=
#                     night_start`), deduplicated by canonical PR URL and head.
#                     Incomplete or malformed generations report `unknown`.
#                     This counts at PR-ready time, not at validation run
#                     start, and emits only `stop_validation`.
#   supervision_stall Oldest unacknowledged wake in `state/.wake-queue` older
#                     than `stall-minutes`, or a latched supervision-host
#                     engine validated against `fm_supervision_host_health_key`
#                     (a corrupt health file, unreadable present
#                     `config/supervision-host`, or unresolvable enabled engine
#                     key reports `unknown`). When `config/supervision-host-off`
#                     is present or `fm_supervision_host_config` reports the
#                     supervision host disabled for this home, a leftover
#                     health file is ignored and no engine latch is read.
#   hc_core           Uses `bin/fm-backend.sh`'s backend resolution
#                     (`fm_backend_resolve` + `fm_backend_validate`) and
#                     `bin/backends/hc.sh`'s session and socket pinning
#                     (`HC_SESSION`, stripping ambient `HC_SOCKET` unless
#                     `FM_HC_SOCKET` pins it). Saves the resolved `backend`,
#                     `hc_target` `{session, socket}`, and `hc_baseline` at
#                     `start`, validates them as a unit during the night, and
#                     queries that target without falling back to ambient
#                     routing; any missing, partial, unresolvable, or
#                     unreadable target or baseline reports `unknown`. With a
#                     valid baseline, a restart is a changed pid, holder
#                     instance, or core id; only when `hc_baseline` is
#                     explicitly `null` does a core whose uptime starts after
#                     the night began count.
#   host_load         1-minute load strictly above `high-load-threshold` for at
#                     least `high-load-minutes`. Keeps its sustained-load timer
#                     across runs only while consecutive checks are at most
#                     twice `high-load-minutes` apart, so `check` must run at
#                     least that often for sustained load to trip.
#
# Level and event conditions:
#   Level conditions are re-evaluated on every `check` and only shape that
#   verdict: night_window, claude_quota, github_api, dev_health,
#   check_machine, validation_cap, host_load, and every "unknown"
#   (unreadable/corrupt) reading (including an unreadable
#   `state/night-stop.json`). A recovered reading gives `continue` on the next
#   run. A dev_health trip during an active night is also kept in the durable
#   stop record's `history` list for the morning board, without latching or
#   setting a reserve-flag; a later passing record on the same target branch
#   clears it.
#   Event conditions latch while a night is active: when failure_streak,
#   supervision_stall, or hc_core reads "tripped", the event is
#   added to the durable stop record's `latched` list, keeps shaping every
#   later verdict of the night (status "latched"), and sets the first
#   configured `reserve-flag` from `config/lane-capacity` so
#   `bin/fm-capacity.sh` admits nothing new. Outside an active night nothing
#   latches, no stop record is written, and no reserve-flag is set.
#   The reserve-flag is created only when absent (never overwritten or
#   restamped) with `set_by=fm-night-check` and a per-creation `token=<id>`
#   line; its exact path and ownership token are persisted in
#   `state/night-active.json`. `end` removes only flags recorded in
#   `state/night-active.json` whose on-disk first two lines still match that
#   ownership token, independent of current `config/lane-capacity`; a foreign
#   or replaced flag is left untouched and reported as "set_externally". When
#   `config/lane-capacity` names no reserve-flag, the verdict carries a warning
#   that `stop_dispatch` cannot be enforced through admission.
#
# Historical verdict vs. live permission (P3 and P2):
#   `verdict [--json]` serves the stored historical `state/night-verdict.json`
#   snapshot for the morning board (P3) without re-polling external sources.
#   `end` clears `night_active` and `allow.two_hour_default` on the stored
#   verdict while retaining the night's historical diagnosis, and `start`
#   clears the previous night's stored verdict and stop record.
#   For live authorization (P2's two-hour default), callers MUST run a fresh
#   `bin/fm-night-check.sh check --json` and verify exit 0,
#   `night_active == true`, matching `night_started_epoch`, and
#   `allow.two_hour_default == true`, refusing on any mismatch or failure.
#
# Non-destructive guarantee: this script never kills, interrupts, or tears down
# any worker, terminal, or service. It only writes its own `state/` records and
# creates or removes its own token-owned reserve-flag.
#
# Unreadable-source invariant: any source that cannot be read, times out, or
# returns malformed data reports that condition as `status="unknown"` with
# `verdict_effect="stop_dispatch"`; it never reads as healthy.
#
# Durable state files under $STATE (written atomically, mode 0600, owned solely
# by this script):
#   state/night-active.json   (schema: fm-night-active.v1)
#     Present while a night is on. Written by `start`, removed by `end`.
#     Carries started_epoch, started_at, resolved window settings, resolved
#     `backend`, optional hc_target {session, socket}, optional hc_baseline
#     {pid, core_id, holder_instance, uptime_ms, started_epoch},
#     `stop_record_expected` (set true once a latched stop record is published
#     for this night), and created_reserve_flags [{path, token}]. While present
#     (or if unreadable/corrupt), `hc-guard` refuses `bin/fm-install-hc.sh`.
#   state/night-verdict.json  (schema: fm-night-verdict.v1)
#     Latest evaluation verdict, rewritten atomically on every `check` and
#     served by `verdict [--json]` as historical evidence for P3.
#     Machine-readable shape:
#       {
#         "schema": "fm-night-verdict.v1",
#         "checked_epoch": <int>,
#         "checked_at": "<UTC ISO-8601>",
#         "night_active": <bool>,
#         "night_started_epoch": <int|null>,
#         "verdict": "continue"|"stop_validation"|"stop_claude"|"stop_dispatch"|"end_night",
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
#             "status": "tripped"|"unknown"|"latched",
#             "verdict_effect": "stop_validation"|"stop_claude"|"stop_dispatch"|"end_night",
#             "reason": "<plain-text reason>"
#           }
#         ],
#         "reasons": ["<plain-text reason>", ...],
#         "latched": [
#           {
#             "condition": "<event condition name>",
#             "verdict_effect": "stop_dispatch"|"end_night",
#             "reason": "<reason when it latched>",
#             "latched_epoch": <int>,
#             "latched_at": "<UTC ISO-8601>"
#           }
#         ],
#         "warnings": ["<plain-text warning>", ...],
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
#           "state": "not_configured"|"absent"|"set_by_night_check"|"set_externally"
#         },
#         "stop_record_path": "<abs-path|null>"
#       }
#   state/night-stop.json     (schema: fm-night-stop.v1)
#     Durable stop record written by the single owner helper on every `check`
#     of an active night from the first latched event or dev_health trip
#     onward, so its latest-verdict snapshot stays current. Carries the
#     `latched` list, the `history` list of dev_health trips ({condition,
#     verdict_effect, reason, first_tripped_epoch, first_tripped_at,
#     last_tripped_epoch, last_tripped_at}; one entry per run of consecutive
#     tripped checks with the same reason), first_tripped_epoch, earliest
#     stall_since_epoch (when
#     supervision_stall latched), core_restarted (when hc_core latched), latest
#     verdict, and tripped reasons. Kept after `end` for P3; cleared by the
#     next `start`. When unreadable or corrupt during an active night, `check`
#     reports `night_stop_record` as a level `unknown`/`stop_dispatch` without
#     inventing a latch, overwriting the file, or changing any reserve-flag.
#   state/night-pr-base-refs.json  (schema: fm-night-pr-base-refs.v1)
#     Cache of `{refs: {"<canonical PR URL>": "<base branch>"}}` filled only by
#     successful `gh pr view --json baseRefName` lookups for legacy post-merge
#     records without `base_ref`. A merged PR's base branch never changes, so
#     entries are kept across nights; an unreadable or invalid cache is
#     ignored and rebuilt from fresh lookups.
#
# Home configuration: config/night-check (local, gitignored, home-local; schema
# owned by docs/configuration.md "Night stop-and-health check").
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_DATA_OVERRIDE
#   FM_NIGHT_NOW_EPOCH       override current epoch seconds (tests)
#   FM_PROC_ROOT_OVERRIDE    override /proc root for Linux loadavg (tests)
#   FM_REVIEW_POLICY_OVERRIDE override review policy path (tests)
#   FM_CREW_STATE_BIN        override fm-crew-state.sh path (tests)
#   FM_HC_BIN                override herdr-core binary path (matching hc.sh)
#   FM_HC_SOCKET             pin hc core socket (matching hc.sh)
#   FM_NIGHT_QUOTA_TIMEOUT, FM_NIGHT_GH_TIMEOUT, FM_NIGHT_HC_TIMEOUT
#                            per-call timeout seconds for quota-axi, gh, and
#                            hc queries (default 10 each)
#
# Exit status:
#   check / start / end: 0 on completion, 1 on refusal or state error, 2 on
#     usage error or missing jq.
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
STATUS_ARCHIVE_FLAG="$CONFIG/status-archive"
ACTIVE_FILE="$STATE/night-active.json"
VERDICT_FILE="$STATE/night-verdict.json"
STOP_FILE="$STATE/night-stop.json"
BASE_REF_CACHE="$STATE/night-pr-base-refs.json"
POLICY_FILE="${FM_REVIEW_POLICY_OVERRIDE:-$FM_ROOT/.github/firstmate-review-policy.json}"
PROC_ROOT="${FM_PROC_ROOT_OVERRIDE:-/proc}"
CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
# Explicit freshness limits (seconds) enforced centrally by evaluate_night_verdict.
LIVE_INPUT_MAX_AGE=60
QUOTA_MAX_AGE=900
CHECK_EVIDENCE_MAX_AGE=1800
HC_TARGET_MAX_AGE=43200
# Startup grace (seconds) for a night ship that has not written a status line.
SHIP_STATUS_GRACE=900

# Approved minimum Claude allowance floors (config may only raise these).
MIN_CLAUDE_STOP_CLAUDE_PCT=25
MIN_CLAUDE_STOP_ALL_PCT=12

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
  printf 'usage: fm-night-check.sh [check [--json] | verdict [--json] | start | end | hc-guard | --help]\n' >&2
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

validate_iana_timezone() {  # <tz>
  local tz=${1:-} dir
  case "$tz" in
    ''|/*|*..*|*//*) return 1 ;;
    *[!A-Za-z0-9._+/:-]*) return 1 ;;
  esac
  case "$tz" in
    UTC|GMT|Etc/UTC|Etc/GMT) return 0 ;;
  esac
  for dir in "${TZDIR:-}" /usr/share/zoneinfo /var/db/timezone/zoneinfo /usr/lib/zoneinfo; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    [ -f "$dir/$tz" ] && [ -r "$dir/$tz" ] && return 0
    return 1
  done
  if type -P python3 >/dev/null 2>&1; then
    python3 -c 'import sys; from zoneinfo import ZoneInfo; ZoneInfo(sys.argv[1])' "$tz" >/dev/null 2>&1
    return $?
  fi
  return 1
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
  validate_iana_timezone "$tz" || return 1
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
  # Reject dangling symlinks: `[ -e ]` is false for a broken symlink, so check
  # `[ -L ]` too before treating the file as absent.
  [ -e "$NIGHT_CONFIG" ] || [ -L "$NIGHT_CONFIG" ] || return 0
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
        if ! validate_iana_timezone "$value"; then
          CONFIG_ERROR="config/night-check line $lineno: unknown or invalid IANA timezone '$value'"
          return 1
        fi
        WINDOW_TZ=$value
        ;;
      claude-stop-claude-pct)
        if ! is_num "$value" || ! jq -en --arg v "$value" --argjson min "$MIN_CLAUDE_STOP_CLAUDE_PCT" \
          '($v|tonumber) >= $min and ($v|tonumber) <= 100' >/dev/null 2>&1; then
          CONFIG_ERROR="config/night-check line $lineno: claude-stop-claude-pct must be $MIN_CLAUDE_STOP_CLAUDE_PCT..100 (cannot weaken approved floor)"
          return 1
        fi
        CLAUDE_STOP_CLAUDE_PCT=$value
        ;;
      claude-stop-all-pct)
        if ! is_num "$value" || ! jq -en --arg v "$value" --argjson min "$MIN_CLAUDE_STOP_ALL_PCT" \
          '($v|tonumber) >= $min and ($v|tonumber) <= 100' >/dev/null 2>&1; then
          CONFIG_ERROR="config/night-check line $lineno: claude-stop-all-pct must be $MIN_CLAUDE_STOP_ALL_PCT..100 (cannot weaken approved floor)"
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
  [ -f "$LANE_CONFIG" ] && [ ! -L "$LANE_CONFIG" ] && [ -r "$LANE_CONFIG" ] || return 1
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

reserve_flag_matches_token() {  # <path> <token>
  local path=$1 token=$2 line1="" line2=""
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 1
  { IFS= read -r line1 && IFS= read -r line2; } < "$path" || return 1
  [ "$line1" = "set_by=fm-night-check" ] && [ "$line2" = "token=$token" ]
}

reserve_flag_state() {  # <path> -> absent | set_by_night_check | set_externally
  local path=$1 first=""
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'absent\n'
  elif [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] \
    && IFS= read -r first < "$path" && [ "$first" = "set_by=fm-night-check" ]; then
    printf 'set_by_night_check\n'
  else
    printf 'set_externally\n'
  fi
}

create_lane_reserve_flag() {  # <path> <token> <verdict> <now_iso> <reasons_summary>
  local path=$1 token=$2 verdict=$3 iso=$4 summary=$5
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
  ( umask 077
    set -C
    printf 'set_by=fm-night-check\ntoken=%s\nat=%s\nverdict=%s\nreasons=%s\n' \
      "$token" "$iso" "$verdict" "$summary" > "$path"
  ) 2>/dev/null
}

status_archive_enabled() {
  [ -f "$STATUS_ARCHIVE_FLAG" ] && [ ! -L "$STATUS_ARCHIVE_FLAG" ]
}

record_created_reserve_flag() {  # <path> <token>
  local path=$1 token=$2 updated
  [ -f "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ] && [ -r "$ACTIVE_FILE" ] || return 1
  updated=$(jq --arg path "$path" --arg token "$token" '
    if .schema != "fm-night-active.v1" then error("invalid") else . end
    | .created_reserve_flags = ((.created_reserve_flags // [])
        | if any(.[]; .path == $path and .token == $token) then .
          else . + [{path: $path, token: $token}] end)
  ' "$ACTIVE_FILE" 2>/dev/null) || return 1
  atomic_write_json "$ACTIVE_FILE" "$updated"
}

mark_stop_record_expected() {
  local updated
  [ -f "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ] && [ -r "$ACTIVE_FILE" ] || return 1
  updated=$(jq '
    if .schema != "fm-night-active.v1" then error("invalid") else . end
    | .stop_record_expected = true
  ' "$ACTIVE_FILE" 2>/dev/null) || return 1
  atomic_write_json "$ACTIVE_FILE" "$updated"
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

# --- hc backend & target resolution (via bin/fm-backend.sh + backends/hc.sh)
# Resolves the active backend with fm_backend_resolve (explicit FM_BACKEND,
# config/backend, or runtime auto-detection including app-terminal), and when hc
# is selected resolves the exact session and socket pin the hc adapter uses
# (stripping ambient HC_SOCKET unless FM_HC_SOCKET supplies the pin).
HC_TARGET_RESOLVED_BACKEND=""
HC_TARGET_SESSION=""
HC_TARGET_SOCKET=""
HC_TARGET_ERROR=""

resolve_hc_target() {
  local res backend session socket signal
  HC_TARGET_RESOLVED_BACKEND=""
  HC_TARGET_SESSION=""
  HC_TARGET_SOCKET=""
  HC_TARGET_ERROR=""
  if [ -e "$CONFIG/backend" ] || [ -L "$CONFIG/backend" ]; then
    if [ -L "$CONFIG/backend" ] || [ ! -f "$CONFIG/backend" ] || [ ! -r "$CONFIG/backend" ]; then
      HC_TARGET_RESOLVED_BACKEND="hc"
      HC_TARGET_ERROR="config/backend is unreadable or unsafe"
      return 1
    fi
  fi
  res=$(
    FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE" \
      bash -c '
        # shellcheck source=bin/fm-backend.sh
        . "$1/fm-backend.sh" || exit 1
        fm_backend_resolve 2>/dev/null || exit 1
        fm_backend_validate "${FM_BACKEND_RESOLVED:-}" >/dev/null 2>&1 || exit 1
        printf "%s\t%s\n" "${FM_BACKEND_RESOLVED:-}" "${FM_BACKEND_DETECT_SIGNAL:-}"
      ' _ "$SCRIPT_DIR" 2>/dev/null
  ) || {
    HC_TARGET_RESOLVED_BACKEND="hc"
    HC_TARGET_ERROR="could not resolve runtime backend via bin/fm-backend.sh"
    return 1
  }
  backend=${res%%	*}
  signal=${res#*	}
  HC_TARGET_RESOLVED_BACKEND=$backend
  if [ "$backend" != "hc" ]; then
    if [ "$signal" = "app-terminal-unusable" ]; then
      HC_TARGET_RESOLVED_BACKEND="hc"
      HC_TARGET_ERROR="live hc app-terminal detected but hc toolchain is unusable"
      return 1
    fi
    return 0
  fi
  session="${HC_SESSION:-default}"
  case "$session" in
    ''|-*|*[!A-Za-z0-9._-]*)
      HC_TARGET_ERROR="invalid hc session name '$session'"
      return 1
      ;;
  esac
  socket="${FM_HC_SOCKET:-}"
  HC_TARGET_SESSION=$session
  HC_TARGET_SOCKET=$socket
  return 0
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

read_hc_status_json() {  # <now> <session> [socket] -> normalized hc status JSON or return 1
  local now=$1 session=$2 socket=${3:-} hbin json rc=0 parsed
  case "$session" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  hbin=$(hc_resolve_bin) || return 1
  # Match bin/backends/hc.sh fm_backend_hc_env_run: always strip
  # HC_TERMINAL_ID/HC_TERMINAL_SOCKET/HC_SCOPE, always strip ambient HC_SOCKET
  # unless an explicit socket pin (FM_HC_SOCKET saved in target) is supplied,
  # and export exact HC_SESSION.
  if [ -n "$socket" ]; then
    json=$(
      unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
      HC_SESSION="$session" HC_SOCKET="$socket" \
        fm_run_timed "$HC_TIMEOUT" "$hbin" server status --json 2>/dev/null </dev/null
    ) || rc=$?
  else
    json=$(
      unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
      HC_SESSION="$session" \
        fm_run_timed "$HC_TIMEOUT" "$hbin" server status --json 2>/dev/null </dev/null
    ) || rc=$?
  fi
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

# --- start / end / verdict ------------------------------------------------
cmd_start() {
  type -P jq >/dev/null 2>&1 || die_usage "jq is required"
  load_check_libs
  if [ -e "$ACTIVE_FILE" ] || [ -L "$ACTIVE_FILE" ]; then
    die "a night run is already active ($ACTIVE_FILE); run 'end' before starting a new night"
  fi
  status_archive_enabled || die "enable config/status-archive for night runs"
  parse_night_config || die "$CONFIG_ERROR"
  local now iso hc_target=null hc_base=null doc
  now=$(now_epoch)
  iso=$(epoch_to_iso "$now")
  if ! resolve_hc_target; then
    die "$HC_TARGET_ERROR"
  fi
  if [ "$HC_TARGET_RESOLVED_BACKEND" = "hc" ]; then
    hc_target=$(jq -cn --arg s "$HC_TARGET_SESSION" --arg sock "$HC_TARGET_SOCKET" \
      '{session: $s, socket: (if $sock == "" then null else $sock end)}')
    hc_base=$(read_hc_status_json "$now" "$HC_TARGET_SESSION" "$HC_TARGET_SOCKET") \
      || die "backend=hc resolved (session '$HC_TARGET_SESSION') but herdr-core server status could not be read for baseline"
  fi
  doc=$(jq -n \
    --argjson now "$now" \
    --arg iso "$iso" \
    --arg ws "$WINDOW_START" \
    --arg ld "$LAST_DISPATCH" \
    --arg we "$WINDOW_END" \
    --arg tz "$WINDOW_TZ" \
    --arg backend "$HC_TARGET_RESOLVED_BACKEND" \
    --argjson hc_target "$hc_target" \
    --argjson hc_base "$hc_base" \
    '{
      schema: "fm-night-active.v1",
      started_epoch: $now,
      started_at: $iso,
      backend: $backend,
      window: {
        start: $ws,
        last_dispatch: $ld,
        end: $we,
        timezone: $tz
      },
      hc_target: $hc_target,
      hc_baseline: $hc_base,
      stop_record_expected: false,
      created_reserve_flags: []
    }') || die "could not build night-active record"
  atomic_write_json "$ACTIVE_FILE" "$doc" || die "could not write $ACTIVE_FILE"
  rm -f -- "$STOP_FILE" "$VERDICT_FILE" 2>/dev/null || true
  printf 'night-check: started at %s (window %s-%s, last-dispatch %s %s)\n' \
    "$iso" "$WINDOW_START" "$WINDOW_END" "$LAST_DISPATCH" "$WINDOW_TZ"
}

cmd_end() {
  local rows rf_path rf_token updated
  if [ -f "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ] && [ -r "$ACTIVE_FILE" ] && type -P jq >/dev/null 2>&1; then
    rows=$(jq -r '
      if .schema == "fm-night-active.v1" then
        (.created_reserve_flags // [])[]
        | select((.path | type == "string" and length > 0) and (.token | type == "string" and length > 0))
        | [.path, .token] | @tsv
      else empty end
    ' "$ACTIVE_FILE" 2>/dev/null) || rows=""
    while IFS=$'\t' read -r rf_path rf_token; do
      [ -n "$rf_path" ] && [ -n "$rf_token" ] || continue
      if reserve_flag_matches_token "$rf_path" "$rf_token"; then
        rm -f -- "$rf_path" || die "could not remove reserve-flag $rf_path"
        printf 'night-check: cleared reserve-flag %s\n' "$rf_path"
      fi
    done <<EOF
$rows
EOF
  fi
  # Mark any stored historical verdict inactive so it can never be mistaken for
  # live two-hour-default authorization after `end`, while keeping the night's
  # diagnosis intact for P3's morning board.
  if [ -f "$VERDICT_FILE" ] && [ ! -L "$VERDICT_FILE" ] && [ -r "$VERDICT_FILE" ] && type -P jq >/dev/null 2>&1; then
    if updated=$(jq 'if .schema == "fm-night-verdict.v1" then .night_active = false | .allow.two_hour_default = false else error("invalid") end' "$VERDICT_FILE" 2>/dev/null); then
      atomic_write_json "$VERDICT_FILE" "$updated" || true
    fi
  fi
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

# --- Condition evaluators ---------------------------------------------------
proof_json() {  # <present> <readable> <observed_epoch_or_null> <max_age_or_null> <scope_or_empty>
  jq -cn \
    --argjson present "$1" \
    --argjson readable "$2" \
    --argjson observed "$3" \
    --argjson max_age "$4" \
    --arg scope "$5" \
    '{
      present: $present,
      readable: $readable,
      observed_epoch: $observed,
      max_age_seconds: $max_age,
      target_scope: (if $scope == "" then null else $scope end)
    }'
}

cond_json() {  # <status> <verdict_effect> <reason> <details_json> [proof_json]
  local proof_arg=${5:-'{"present":false,"readable":false,"observed_epoch":null,"max_age_seconds":null,"target_scope":null}'}
  jq -cn \
    --arg status "$1" \
    --arg effect "$2" \
    --arg reason "$3" \
    --argjson details "${4:-null}" \
    --argjson proof "$proof_arg" \
    '{status: $status, verdict_effect: $effect, reason: $reason, details: $details, proof: $proof}'
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
  local cur_hhmm cur_min start_min last_min end_min details prf
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
  prf=$(proof_json true true "$now" "$LIVE_INPUT_MAX_AGE" "$WINDOW_TZ")
  if ! in_time_interval "$cur_min" "$start_min" "$end_min"; then
    cond_json tripped end_night \
      "outside night window ($cur_hhmm $WINDOW_TZ is not within $WINDOW_START-$WINDOW_END)" "$details" "$prf"
    return 0
  fi
  if [ "$last_min" -ne "$end_min" ] && in_time_interval "$cur_min" "$last_min" "$end_min"; then
    cond_json tripped stop_dispatch \
      "past last-dispatch cut-off ($cur_hhmm >= $LAST_DISPATCH $WINDOW_TZ; draining until $WINDOW_END)" "$details" "$prf"
    return 0
  fi
  cond_json ok continue "" "$details" "$prf"
}

eval_claude_quota() {
  local qbin json rc=0 parsed
  qbin=$(type -P quota-axi 2>/dev/null) || { cond_json unknown stop_dispatch "quota-axi is not installed" '{}'; return 0; }
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
    --argjson max_age "$QUOTA_MAX_AGE" \
    "$FM_QUOTA_ROW_JQ"'
    def rem:
      if (.percentRemaining | type) == "number" then .percentRemaining
      elif (.percentUsed | type) == "number" then (100 - .percentUsed)
      else null end
      | if . != null and . >= 0 and . <= 100 then . else null end;
    def iso_epoch:
      if type == "string" and length > 0 then
        (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null)
      else null end;
    def bad_proof: {present: false, readable: false, observed_epoch: null, max_age_seconds: $max_age, target_scope: "claude:five_hour+seven_day"};
    quota_row(.; "claude"; "") as $row
    | if ($row // null) == null then
        {status: "unknown", verdict_effect: "stop_dispatch", reason: "quota-axi snapshot has no claude provider row", details: {}, proof: bad_proof}
      elif (($row.state | type) != "object")
           or ($row.state.stale != false)
           or (($row.state.status // "") != "fresh") then
        {
          status: "unknown",
          verdict_effect: "stop_dispatch",
          reason: "quota-axi Claude reading is stale or not fresh (status=\($row.state.status // "missing"), stale=\($row.state.stale // "missing"))",
          details: {state_status: ($row.state.status // null), state_stale: ($row.state.stale // null)},
          proof: {present: true, readable: true, observed_epoch: (($row.state.refreshedAt // .generatedAt) | iso_epoch), max_age_seconds: $max_age, target_scope: "claude:five_hour+seven_day"}
        }
      else
        (($row.state.refreshedAt // .generatedAt) | iso_epoch) as $obs
        | ([ ($row.windows // [])[] | select(.id == "five_hour") | rem | select(. != null) ] | first // null) as $five
        | ([ ($row.windows // [])[] | select(.id == "seven_day") | rem | select(. != null) ] | first // null) as $week
        | {present: ($five != null and $week != null and $obs != null), readable: true, observed_epoch: $obs, max_age_seconds: $max_age, target_scope: "claude:five_hour+seven_day"} as $prf
        | if $obs == null then
            {status: "unknown", verdict_effect: "stop_dispatch", reason: "quota-axi Claude reading has no valid refreshedAt timestamp", details: {five_hour_remaining_pct: $five, seven_day_remaining_pct: $week}, proof: $prf}
          elif $five == null and $week == null then
            {status: "unknown", verdict_effect: "stop_dispatch", reason: "quota-axi returned neither five_hour nor seven_day Claude window", details: {five_hour_remaining_pct: null, seven_day_remaining_pct: null}, proof: $prf}
          elif $five == null then
            {status: "unknown", verdict_effect: "stop_dispatch", reason: "quota-axi reading is missing five_hour Claude window", details: {five_hour_remaining_pct: null, seven_day_remaining_pct: $week}, proof: $prf}
          elif $week == null then
            {status: "unknown", verdict_effect: "stop_dispatch", reason: "quota-axi reading is missing seven_day Claude window", details: {five_hour_remaining_pct: $five, seven_day_remaining_pct: null}, proof: $prf}
          else
            (if $five <= $week then {id: "five_hour", rem: $five} else {id: "seven_day", rem: $week} end) as $worst
            | {
                five_hour_remaining_pct: $five,
                seven_day_remaining_pct: $week,
                limiting_window: $worst.id,
                min_remaining_pct: $worst.rem,
                stop_claude_floor_pct: $stop_claude,
                stop_all_floor_pct: $stop_all,
                refreshed_epoch: $obs
              } as $det
            | if $worst.rem < $stop_all then
                {status: "tripped", verdict_effect: "stop_dispatch", reason: "Claude \($worst.id) quota remaining (\($worst.rem)%) is below \($stop_all)% all-work floor", details: $det, proof: $prf}
              elif $worst.rem < $stop_claude then
                {status: "tripped", verdict_effect: "stop_claude", reason: "Claude \($worst.id) quota remaining (\($worst.rem)%) is below \($stop_claude)% Claude-work floor", details: $det, proof: $prf}
              else
                {status: "ok", verdict_effect: "continue", reason: "", details: $det, proof: $prf}
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

resolve_gh_bin() {
  type -P gh 2>/dev/null
}

eval_github_api() {  # <now>
  local now=$1 gbin json rc=0 parsed
  gbin=$(resolve_gh_bin) || { cond_json unknown stop_dispatch "gh CLI is not installed" '{}'; return 0; }
  json=$(fm_run_timed "$GH_TIMEOUT" "$gbin" api rate_limit 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    cond_json unknown stop_dispatch "gh api rate_limit timed out after ${GH_TIMEOUT}s" '{}'
    return 0
  elif [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    cond_json unknown stop_dispatch "gh api rate_limit failed (exit $rc)" '{}'
    return 0
  fi
  # shellcheck disable=SC2016
  parsed=$(printf '%s\n' "$json" | jq -c \
    --argjson floor "$GITHUB_API_FLOOR" \
    --argjson now "$now" \
    --argjson max_age "$LIVE_INPUT_MAX_AGE" '
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
      | {present: true, readable: true, observed_epoch: $now, max_age_seconds: $max_age, target_scope: "github:core"} as $prf
      | if $rem < $floor then
          {status: "tripped", verdict_effect: "stop_dispatch", reason: "GitHub core API remaining (\($rem)) is below floor (\($floor))", details: $det, proof: $prf}
        else
          {status: "ok", verdict_effect: "continue", reason: "", details: $det, proof: $prf}
        end
    else
      {status: "unknown", verdict_effect: "stop_dispatch", reason: "gh api rate_limit returned unexpected JSON shape", details: {}, proof: {present: false, readable: false, observed_epoch: null, max_age_seconds: $max_age, target_scope: "github:core"}}
    end
  ' 2>/dev/null) || parsed=""
  if [ -z "$parsed" ]; then
    cond_json unknown stop_dispatch "gh api rate_limit returned invalid JSON" '{}'
    return 0
  fi
  printf '%s\n' "$parsed"
}

extract_status_timeline() {  # <file> -> "<first_at>\t<term_at>\t<verb>\t<has_terminal>\t<file_gen>"
  local file=$1 parsed first_at term_at verb has_term file_gen m
  parsed=$(awk '
    {
      if (match($0, /\[at=[0-9]+\]/)) {
        a = substr($0, RSTART + 4, RLENGTH - 5) + 0
        if (first_at == "" || a < first_at) first_at = a
      }
      if (file_gen == "" && match($0, /\[(spawn_gen|gen)=[^]]+\]/)) {
        g = substr($0, RSTART + 1, RLENGTH - 2)
        sub(/^(spawn_gen|gen)=/, "", g)
        file_gen = g
      }
      if ($0 ~ /^(done|failed)([[:space:]]+\[[^]]+\])*:/) {
        last = $0
      }
    }
    END {
      has_t = 0; v = ""; t = ""
      if (last != "") {
        has_t = 1
        v = last
        sub(/[: ].*$/, "", v)
        if (match(last, /\[at=[0-9]+\]/)) {
          t = substr(last, RSTART + 4, RLENGTH - 5)
        }
      }
      printf "%s\t%s\t%s\t%d\t%s\n", first_at, t, v, has_t, file_gen
    }
  ' "$file" 2>/dev/null) || return 1
  IFS=$'\t' read -r first_at term_at verb has_term file_gen <<EOF
$parsed
EOF
  if [ "$has_term" = "1" ] && ! is_uint "$term_at"; then
    m=$(file_mtime "$file") || return 1
    term_at=$m
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$first_at" "$term_at" "$verb" "$has_term" "$file_gen"
}

meta_spawn_epoch() {  # <meta-file> -> prints spawn epoch or returns 1
  local meta=$1 sg
  sg=$(sed -n 's/^spawn_gen=s\([0-9][0-9]*\)\..*/\1/p' "$meta" 2>/dev/null | head -1)
  if is_uint "$sg"; then
    printf '%s\n' "$sg"
    return 0
  fi
  sg=$(sed -n 's/^spawned_epoch=\([0-9][0-9]*\)$/\1/p' "$meta" 2>/dev/null | head -1)
  if is_uint "$sg"; then
    printf '%s\n' "$sg"
    return 0
  fi
  file_mtime "$meta"
}

task_has_archived_status() {  # <task-id> -> 0 if at least one data/<id>/status*.log exists
  local id=$1 af
  for af in "$DATA/$id"/status.log "$DATA/$id"/status.[0-9]*.log; do
    if [ -e "$af" ] || [ -L "$af" ]; then
      return 0
    fi
  done
  return 1
}

archived_task_kind() {  # <task-id> -> prints ship | scout | secondmate from data/<id>/brief.md
  local brief="$DATA/$1/brief.md"
  if [ -f "$brief" ] && [ ! -L "$brief" ] && [ -r "$brief" ]; then
    if grep -q '^Delivery contract: mode=' "$brief" 2>/dev/null; then
      printf 'ship\n'
      return 0
    fi
    if grep -q '^This is a SCOUT task:\|^This is a LANDING CREW task:' "$brief" 2>/dev/null; then
      printf 'scout\n'
      return 0
    fi
    if grep -q '^You are a persistent second mate managed by the main firstmate\.' "$brief" 2>/dev/null; then
      printf 'secondmate\n'
      return 0
    fi
  fi
  printf 'ship\n'
}

eval_failure_streak() {  # <since_epoch> <night_active> <now>
  local since=$1 night_active=${2:-false} now=$3
  local rows="" meta id kind spawn_ep sg gen_key sf res
  local first_at term_at verb has_term file_gen
  local non_ship_ids=" " pre_night_live_ids=" " tdir af

  if [ "$night_active" = true ] && ! status_archive_enabled; then
    cond_json unknown stop_dispatch "enable config/status-archive for night runs" '{}'
    return 0
  fi

  # Pass 1: live task records under $STATE/*.meta
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if [ -L "$meta" ] || [ ! -f "$meta" ] || [ ! -r "$meta" ]; then
      cond_json unknown stop_dispatch "task metadata $meta is unreadable or unsafe" '{}'
      return 0
    fi
    id=$(basename "$meta" .meta)
    kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | head -1)
    # Limit failure streak strictly to kind=ship tasks (leave out scouts,
    # secondmates, and untyped records).
    if [ "$kind" != "ship" ]; then
      non_ship_ids="${non_ship_ids}${id} "
      continue
    fi
    spawn_ep=$(meta_spawn_epoch "$meta") || {
      cond_json unknown stop_dispatch "could not determine spawn epoch from $meta" '{}'
      return 0
    }
    # Only count ship tasks spawned inside the night window.
    if [ "$spawn_ep" -lt "$since" ]; then
      pre_night_live_ids="${pre_night_live_ids}${id} "
      continue
    fi
    sg=$(sed -n 's/^spawn_gen=//p' "$meta" 2>/dev/null | head -1)
    gen_key="${sg:-live:$spawn_ep}"
    sf="$STATE/$id.status"
    if [ -e "$sf" ] || [ -L "$sf" ]; then
      if [ -L "$sf" ] || [ ! -f "$sf" ] || [ ! -r "$sf" ]; then
        cond_json unknown stop_dispatch "status log $sf is unreadable or unsafe" '{}'
        return 0
      fi
      res=$(extract_status_timeline "$sf") || {
        cond_json unknown stop_dispatch "could not read terminal status from $sf" '{}'
        return 0
      }
      IFS=$'\t' read -r first_at term_at verb has_term file_gen <<EOF
$res
EOF
      if [ "$has_term" = "1" ] && [ "$term_at" -ge "$since" ]; then
        rows="${rows}${term_at}	${id}	${gen_key}	${verb}	live
"
      fi
    elif ! task_has_archived_status "$id"; then
      if [ "$now" -ge "$spawn_ep" ] && [ $((now - spawn_ep)) -lt "$SHIP_STATUS_GRACE" ]; then
        continue
      fi
      cond_json unknown stop_dispatch "night-window ship $id has neither live status nor archived status" '{}'
      return 0
    fi
  done

  # Pass 2: retired status logs under $DATA/<id>/status.log and status.<N>.log
  if [ -e "$DATA" ] || [ -L "$DATA" ]; then
    if [ ! -d "$DATA" ] || [ ! -r "$DATA" ]; then
      cond_json unknown stop_dispatch "task data directory $DATA is unreadable" '{}'
      return 0
    fi
    for tdir in "$DATA"/*; do
      [ -e "$tdir" ] || [ -L "$tdir" ] || continue
      [ -d "$tdir" ] && [ ! -L "$tdir" ] || continue
      id=$(basename "$tdir")
      [ "$id" != "pr-review-ledger" ] || continue
      case "$non_ship_ids" in *" $id "*) continue ;; esac
      case "$pre_night_live_ids" in *" $id "*) continue ;; esac
      [ "$(archived_task_kind "$id")" = ship ] || continue
      for af in "$tdir"/status.log "$tdir"/status.[0-9]*.log; do
        [ -e "$af" ] || [ -L "$af" ] || continue
        if [ -L "$af" ] || [ ! -f "$af" ] || [ ! -r "$af" ]; then
          cond_json unknown stop_dispatch "archived status log $af is unreadable or unsafe" '{}'
          return 0
        fi
        res=$(extract_status_timeline "$af") || {
          cond_json unknown stop_dispatch "could not read terminal status from archived log $af" '{}'
          return 0
        }
        IFS=$'\t' read -r first_at term_at verb has_term file_gen <<EOF
$res
EOF
        [ "$has_term" = "1" ] || continue
        [ "$term_at" -ge "$since" ] || continue
        if is_uint "$first_at" && [ "$first_at" -lt "$since" ]; then
          continue
        fi
        gen_key="${file_gen:-archive:$(basename "$af"):${first_at:-$term_at}}"
        rows="${rows}${term_at}	${id}	${gen_key}	${verb}	archive
"
      done
    done
  fi

  # shellcheck disable=SC2016
  printf '%s' "$rows" | jq -Rsc \
    --argjson limit "$FAILURE_STREAK_LIMIT" \
    --argjson since "$since" \
    --argjson now "$now" \
    --argjson max_age "$LIVE_INPUT_MAX_AGE" '
    split("\n")
    | map(select(. != "") | split("\t")
          | {at: (.[0] | tonumber), id: .[1], spawn_gen: .[2], verb: .[3], source: .[4]})
    | group_by([.id, .spawn_gen])
    | map(max_by(.at))
    | ([ .[] | select(.source == "live") ]) as $live
    | map(select(.source == "live" or (. as $r | any($live[]; .id == $r.id and .at == $r.at and .verb == $r.verb) | not)))
    | sort_by([.at, .id, .spawn_gen])
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
    | {present: true, readable: true, observed_epoch: $now, max_age_seconds: $max_age, target_scope: "night:kind=ship"} as $prf
    | if $res.streak >= $limit then
        {status: "tripped", verdict_effect: "stop_dispatch", reason: "failure streak of \($res.streak) consecutive failed night ship tickets (\($res.ids | join(", ")))", details: $det, proof: $prf}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det, proof: $prf}
      end
  '
}

resolve_pr_base_ref() {  # <pr-url> -> prints baseRefName or returns 1
  local url=$1 gbin json rc=0 ref
  gbin=$(resolve_gh_bin) || return 1
  json=$(fm_run_timed "$GH_TIMEOUT" "$gbin" pr view "$url" --json baseRefName 2>/dev/null </dev/null) || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$json" ] || return 1
  ref=$(printf '%s\n' "$json" | jq -er '.baseRefName | select(type == "string" and length > 0)' 2>/dev/null) || return 1
  printf '%s\n' "$ref"
}

load_base_ref_cache() {  # -> prints {"<pr-url>": "<base ref>"} (empty when absent or invalid)
  local out
  if [ -f "$BASE_REF_CACHE" ] && [ ! -L "$BASE_REF_CACHE" ] && [ -r "$BASE_REF_CACHE" ] \
    && out=$(jq -c 'if .schema == "fm-night-pr-base-refs.v1" and (.refs | type == "object") then .refs | with_entries(select(.value | type == "string" and length > 0)) else error("invalid") end' "$BASE_REF_CACHE" 2>/dev/null) \
    && [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    printf '{}\n'
  fi
}

resolve_pr_merge_state() {  # <pr-url> -> prints "<state>\t<baseRefName>" or returns 1
  local url=$1 gbin json rc=0
  gbin=$(resolve_gh_bin) || return 1
  json=$(fm_run_timed "$GH_TIMEOUT" "$gbin" pr view "$url" --json state,baseRefName 2>/dev/null </dev/null) || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$json" ] || return 1
  printf '%s\n' "$json" | jq -er '
    select((.state | type == "string" and length > 0) and ((.baseRefName // "") | type == "string"))
    | [.state, (.baseRefName // "")] | @tsv' 2>/dev/null
}

eval_dev_health() {  # <now> <since_epoch>
  local now=$1 since=$2 f records_json="[]" candidates_json="[]" merges_json="[]" count=0 parsed
  local cand url forge state forge_ref night_repos lookup_urls fallback_ref
  local base_refs cache_publish_ok=true cache_warning=""
  local scope="per-(repo,target_branch); night merges forge-confirmed"
  base_refs=$(load_base_ref_cache)
  if ! resolve_ledger_dir; then
    cond_json unknown stop_dispatch "$LEDGER_DIR_ERROR" '{}'
    return 0
  fi
  if [ ! -e "$LEDGER_DIR" ] && [ ! -L "$LEDGER_DIR" ]; then
    cond_json ok continue "" '{"failed_targets":[],"unverified_merges":[],"night_merges":0,"checked_ledgers":0,"cache_publish_ok":true,"cache_warning":null}' \
      "$(proof_json true true "$now" "$LIVE_INPUT_MAX_AGE" "$scope")"
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
    if ! jq -e '.schema == "firstmate-pr-review-ledger.v1" and (.url | type == "string" and length > 0) and (.generations | type == "array" and length > 0)' "$f" >/dev/null 2>&1; then
      cond_json unknown stop_dispatch "review ledger $(basename "$f") is malformed JSON" '{}'
      return 0
    fi
    count=$((count + 1))
    # Validate every passed/failed post_merge_verifications record strictly
    # before selection: malformed outcome, missing/invalid integer
    # recorded_epoch, or malformed branch field fails closed as unknown rather
    # than sorting as epoch 0 or dropping the record. A dated not-applicable
    # record only shows that its own merge was verified.
    parsed=$(jq -c --argjson since "$since" '
      def uint: type == "number" and . >= 0 and floor == .;
      def bad_branch:
        (has("base_ref") and .base_ref != null and (.base_ref | type != "string" or length == 0))
        or (has("baseRefName") and .baseRefName != null and (.baseRefName | type != "string" or length == 0))
        or (has("target_branch") and .target_branch != null and (.target_branch | type != "string" or length == 0));
      .url as $u
      | ($u | sub("/(-/)?(pull|merge_requests)/.*$"; "")) as $repo
      | if ($repo | length) == 0 then error("invalid url repo") else . end
      | ([ .generations[] | .merge_decision
           | select(type == "object" and .decision == "merge")
           | if (.verified_epoch | uint) then .verified_epoch else error("invalid merge decision verified_epoch") end
           | select(. >= $since) ] | max) as $merge_epoch
      | [ .generations[]
          | if (.post_merge_verifications == null) then empty
            elif (.post_merge_verifications | type) != "array" then error("post_merge_verifications not array")
            else .post_merge_verifications[]
            end
          | if (type != "object") then error("verification not object") else . end
          | if (.applicability == "not-applicable") and (.outcome == null or .outcome == "") then
              if (.recorded_epoch | uint) and (bad_branch | not) then
                {repo: $repo, url: $u, head: (.head // null),
                 base_ref: (.base_ref // .baseRefName // .target_branch // ""),
                 outcome: "not-applicable", recorded_epoch: .recorded_epoch}
              else empty end
            elif (.outcome != "passed" and .outcome != "failed") then
              error("invalid post-merge outcome")
            elif (.recorded_epoch | uint | not) then
              error("missing or invalid recorded_epoch")
            elif bad_branch then
              error("invalid branch field type")
            else
              {
                repo: $repo,
                url: $u,
                head: (.head // null),
                base_ref: (.base_ref // .baseRefName // .target_branch // ""),
                outcome: .outcome,
                recorded_epoch: .recorded_epoch
              }
            end ] as $rows
      | {
          rows: $rows,
          candidate: (if $merge_epoch == null then null
                      else {url: $u, repo: $repo, merge_epoch: $merge_epoch,
                            own_verified: any($rows[]; .recorded_epoch >= $merge_epoch)} end)
        }
    ' "$f" 2>/dev/null) || {
      cond_json unknown stop_dispatch "review ledger $(basename "$f") contains incomplete or malformed post-merge verification record or merge decision" '{}'
      return 0
    }
    records_json=$(jq -cn --argjson a "$records_json" --argjson p "$parsed" '$a + $p.rows')
    candidates_json=$(jq -cn --argjson a "$candidates_json" --argjson p "$parsed" '$a + (if $p.candidate == null then [] else [$p.candidate] end)')
  done

  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if [ "$(printf '%s\n' "$cand" | jq -r '.own_verified')" = true ]; then
      merges_json=$(jq -cn --argjson a "$merges_json" --argjson m "$cand" '$a + [$m + {forge_base_ref: null}]')
      continue
    fi
    url=$(printf '%s\n' "$cand" | jq -r '.url')
    if ! forge=$(resolve_pr_merge_state "$url"); then
      cond_json unknown stop_dispatch "could not confirm the forge merge state of night merge decision $url" '{}'
      return 0
    fi
    state=${forge%%	*}
    forge_ref=${forge#*	}
    [ "$state" = MERGED ] || continue
    merges_json=$(jq -cn --argjson a "$merges_json" --argjson m "$cand" --arg r "$forge_ref" '$a + [$m + {forge_base_ref: $r}]')
  done <<EOF
$(printf '%s\n' "$candidates_json" | jq -c '.[]')
EOF

  night_repos=$(printf '%s\n' "$merges_json" | jq -c '[.[].repo] | unique')
  lookup_urls=$(printf '%s\n' "$records_json" | jq -r --argjson repos "$night_repos" '
    . as $all
    | [ .[] | select(.base_ref == "" and (.outcome == "failed"
          or (.outcome == "passed" and (. as $p
            | any($repos[]; . == $p.repo)
              or any($all[]; .outcome == "failed" and .repo == $p.repo and .recorded_epoch <= $p.recorded_epoch)))))
        | .url ] | unique | .[]')
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    fallback_ref=$(printf '%s\n' "$base_refs" | jq -r --arg u "$url" '.[$u] // empty')
    if [ -z "$fallback_ref" ]; then
      if ! fallback_ref=$(resolve_pr_base_ref "$url"); then
        cond_json unknown stop_dispatch "could not resolve target branch for post-merge verification on $url" '{}'
        return 0
      fi
      base_refs=$(printf '%s\n' "$base_refs" | jq -c --arg u "$url" --arg r "$fallback_ref" '.[$u] = $r')
      if ! atomic_write_json "$BASE_REF_CACHE" "$(jq -cn --argjson refs "$base_refs" '{schema: "fm-night-pr-base-refs.v1", refs: $refs}')"; then
        cache_publish_ok=false
        cache_warning="could not publish legacy PR base-ref cache at $BASE_REF_CACHE; successful forge lookup will repeat until cache publication succeeds"
      fi
    fi
    records_json=$(printf '%s\n' "$records_json" | jq -c --arg u "$url" --arg ref "$fallback_ref" '
      map(if .url == $u and .base_ref == "" then .base_ref = $ref else . end)
    ')
  done <<EOF
$lookup_urls
EOF

  # shellcheck disable=SC2016
  printf '%s\n' "$records_json" | jq -c \
    --argjson merges "$merges_json" \
    --argjson checked "$count" \
    --argjson now "$now" \
    --argjson max_age "$LIVE_INPUT_MAX_AGE" \
    --argjson cache_ok "$cache_publish_ok" \
    --arg cache_warn "$cache_warning" \
    --arg scope "$scope" '
    [ .[] | select((.outcome == "passed" or .outcome == "failed") and .base_ref != "") ] as $outcomes
    | [ $outcomes | group_by([.repo, .base_ref])[] | max_by(.recorded_epoch) ] as $latest
    | [ $latest[] | select(.outcome == "failed") ] as $failed
    | [ $merges[] | . as $m
        | select(($m.own_verified or any($outcomes[]; .repo == $m.repo and .base_ref == $m.forge_base_ref
            and .recorded_epoch >= $m.merge_epoch)) | not)
        | {url, repo, merge_epoch} ] as $unverified
    | {
        failed_targets: $failed,
        unverified_merges: $unverified,
        night_merges: ($merges | length),
        checked_ledgers: $checked,
        cache_publish_ok: $cache_ok,
        cache_warning: (if $cache_warn == "" then null else $cache_warn end)
      } as $det
    | {present: true, readable: true, observed_epoch: $now, max_age_seconds: $max_age, target_scope: $scope} as $prf
    | if ($unverified | length) > 0 then
        {status: "unknown", verdict_effect: "stop_dispatch", reason: "no post-merge verification recorded after the forge-confirmed night merge of \([$unverified[].url] | join(", "))", details: $det, proof: $prf}
      elif ($failed | length) > 0 then
        {status: "tripped", verdict_effect: "stop_dispatch", reason: "latest post-merge check failed in review ledger for \([$failed[] | "\(.url) (\(.base_ref))"] | join(", "))", details: $det, proof: $prf}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det, proof: $prf}
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

is_sha40() {
  case "${1:-}" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      return 0 ;;
    *) return 1 ;;
  esac
}

crew_state_token() {  # <fm-crew-state-line> -> prints state token or returns 1
  local line=$1 rest tok
  case "$line" in
    'state: '*) rest=${line#'state: '} ;;
    *) return 1 ;;
  esac
  tok=${rest%%' · '*}
  tok=${tok%% *}
  case "$tok" in
    working|paused|parked|done|failed|needs-decision|blocked|idle|unknown)
      printf '%s\n' "$tok"
      return 0 ;;
    *) return 1 ;;
  esac
}

crew_state_waiting_for_ci() {  # <fm-crew-state-line> -> 0 if declared wait for check/CI admission
  local line=$1 detail lower
  case "$line" in
    'state: paused '*) ;;
    *) return 1 ;;
  esac
  # Strip prefix up to the second " · " separator (`state: paused · source: <src> · <detail>`)
  detail=${line#*' · '}
  detail=${detail#*' · '}
  detail=${detail%%' · budget:'*}
  lower=$(printf '%s' "$detail" | tr '[:upper:]' '[:lower:]')
  printf '%s\n' "$lower" | grep -Eq '(ci[[:space:]_-]*(admission|slot|lease|queue|check|run)|check[[:space:]_-]*(slot|machine|admission|lease|queue)|waiting (for|on) (ci|check|a check|a ci)|awaiting (ci|check|a check|a ci))'
}

task_latest_paused_epoch() {  # <status-file> -> prints epoch or 0
  local sf=$1 at
  [ -f "$sf" ] && [ ! -L "$sf" ] && [ -r "$sf" ] || { printf '0\n'; return 0; }
  at=$(awk '
    /^paused([[:space:]]+\[[^]]+\])*:/ {
      if (match($0, /\[at=[0-9]+\]/)) last = substr($0, RSTART + 4, RLENGTH - 5)
    }
    END { if (last != "") print last }
  ' "$sf" 2>/dev/null) || at=""
  if is_uint "$at"; then
    printf '%s\n' "$at"
  else
    printf '0\n'
  fi
}

eval_check_machine() {  # <now>
  local now=$1 meta id kind pr pr_head cs_out cs_rc cs_tok paused_at ledger_path head_key waiting_json="[]"
  local oldest_cp_epoch=""
  if ! resolve_ledger_dir; then
    cond_json unknown stop_dispatch "$LEDGER_DIR_ERROR" '{}'
    return 0
  fi
  if [ ! -x "$CREW_STATE_BIN" ]; then
    cond_json unknown stop_dispatch "crew state reader $CREW_STATE_BIN is unavailable" '{}'
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
    pr_head=$(sed -n 's/^pr_head=//p' "$meta" 2>/dev/null | head -1)
    id=$(basename "$meta" .meta)
    cs_rc=0
    cs_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
      FM_DATA_OVERRIDE="$DATA" FM_CREW_STATE_NO_FORGE=1 "$CREW_STATE_BIN" "$id" 2>/dev/null) || cs_rc=$?
    if [ "$cs_rc" -ne 0 ] || [ -z "$cs_out" ]; then
      cond_json unknown stop_dispatch "could not read current crew state for $id" '{}'
      return 0
    fi
    cs_tok=$(crew_state_token "$cs_out") || {
      cond_json unknown stop_dispatch "crew state for $id returned malformed output" '{}'
      return 0
    }
    if [ "$cs_tok" = "unknown" ]; then
      cond_json unknown stop_dispatch "current crew state for $id is unknown ($cs_out)" '{}'
      return 0
    fi
    if ! crew_state_waiting_for_ci "$cs_out"; then
      continue
    fi
    paused_at=$(task_latest_paused_epoch "$STATE/$id.status")
    # Exclude a wait only on current, head-matched evidence of actively running
    # checks (IN_PROGRESS/RUNNING), completed pass/skipping required checks
    # matching bin/fm-pr-review.sh, or a head-verified merge decision.
    if ledger_path=$(pr_url_ledger_path "$pr") && { [ -e "$ledger_path" ] || [ -L "$ledger_path" ]; }; then
      if [ -L "$ledger_path" ] || [ ! -f "$ledger_path" ] || [ ! -r "$ledger_path" ]; then
        cond_json unknown stop_dispatch "review ledger $ledger_path is unreadable or unsafe" '{}'
        return 0
      fi
      local ledger_info ledger_state ledger_head
      ledger_info=$(jq -r \
        --arg head "$pr_head" \
        --argjson now "$now" \
        --argjson max_age "$CHECK_EVIDENCE_MAX_AGE" \
        --argjson paused_at "$paused_at" '
        def sha40: type == "string" and test("^[0-9a-fA-F]{40}$");
        def valid_status:
          type == "string" and (. == "COMPLETED" or . == "IN_PROGRESS" or . == "RUNNING"
            or . == "QUEUED" or . == "PENDING" or . == "WAITING" or . == "EXPECTED"
            or . == "REQUESTED" or . == "FAILURE" or . == "ERROR" or . == "CANCELLED"
            or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE"
            or . == "STALE" or . == "NEUTRAL" or . == "SKIPPED" or . == "SUCCESS");
        if .schema != "firstmate-pr-review-ledger.v1"
           or (.generations | type != "array" or length == 0)
           or (.current_head | sha40 | not)
           or (.generations[-1] | type != "object")
           or (.generations[-1].head | sha40 | not)
           or (.generations[-1].head != .current_head) then
          "invalid\t"
        else
          (.generations[-1]) as $g
          | (.current_head) as $cur
          | if $head != "" and (($head | sha40 | not) or $head != $cur) then
              "head_mismatch\t"
            elif ($g.merge_decision | type == "object")
                 and ($g.merge_decision.decision // "") == "merge"
                 and ($g.merge_decision.verified_head // "") == $cur then
              "done\t\($cur)"
            elif ($g.checkpoints != null and ($g.checkpoints | type != "array")) then
              "invalid\t"
            elif (($g.checkpoints // []) | length) > 0 then
              ($g.checkpoints[-1]) as $cp
              | if ($cp | type != "object")
                   or ($cp.head | sha40 | not)
                   or ($cp.at_epoch | type != "number" or . < 0 or floor != .)
                   or ($cp.checks | type != "array") then
                  "invalid\t"
                elif $cp.head != $cur
                     or ($now - $cp.at_epoch) > $max_age
                     or $cp.at_epoch > ($now + 60)
                     or ($paused_at > 0 and $cp.at_epoch < $paused_at) then
                  "waiting\t\($cur)\t"
                elif ($cp.checks | length) == 0 then
                  "waiting\t\($cur)"
                elif any($cp.checks[]; (type != "object") or (.status | valid_status | not) or (.conclusion != null and (.conclusion | type != "string"))) then
                  "invalid_check\t\($cur)"
                elif any($cp.checks[]; .status == "IN_PROGRESS" or .status == "RUNNING") then
                  "running\t\($cur)\t\($cp.at_epoch)"
                elif all($cp.checks[]; .status == "COMPLETED" and (.conclusion == "pass" or .conclusion == "skipping")) then
                  "done\t\($cur)\t\($cp.at_epoch)"
                else
                  "waiting\t\($cur)\t"
                end
            else
              "waiting\t\($cur)\t"
            end
        end
      ' "$ledger_path" 2>/dev/null) || ledger_info="invalid		"
      local ledger_cp_ep=""
      IFS=$'\t' read -r ledger_state ledger_head ledger_cp_ep <<EOF
$ledger_info
EOF
      case "$ledger_state" in
        invalid)
          cond_json unknown stop_dispatch "review ledger $(basename "$ledger_path") is malformed" '{}'
          return 0
          ;;
        head_mismatch)
          cond_json unknown stop_dispatch "task $id pr_head does not match current review ledger head" '{}'
          return 0
          ;;
        invalid_check)
          cond_json unknown stop_dispatch "review ledger $(basename "$ledger_path") contains malformed check status" '{}'
          return 0
          ;;
        done|running)
          if is_uint "$ledger_cp_ep"; then
            if [ -z "$oldest_cp_epoch" ] || [ "$ledger_cp_ep" -lt "$oldest_cp_epoch" ]; then
              oldest_cp_epoch=$ledger_cp_ep
            fi
          fi
          continue ;;
      esac
      [ -n "$pr_head" ] || pr_head=$ledger_head
    fi
    if ! is_sha40 "$pr_head"; then
      cond_json unknown stop_dispatch "task $id waiting for CI admission has no confirmed 40-char PR head" '{}'
      return 0
    fi
    head_key="${pr}#${pr_head}"
    waiting_json=$(printf '%s\n' "$waiting_json" | jq -c \
      --arg id "$id" --arg pr "$pr" --arg head "$pr_head" --arg key "$head_key" '
      if any(.[]; .key == $key) then .
      else . + [{key: $key, task: $id, pr: $pr, head: $head}] end
    ')
  done
  local obs_ep=${oldest_cp_epoch:-$now}
  # shellcheck disable=SC2016
  printf '%s\n' "$waiting_json" | jq -c \
    --argjson limit "$CHECK_QUEUE_LIMIT" \
    --argjson obs "$obs_ep" \
    --argjson max_age "$CHECK_EVIDENCE_MAX_AGE" '
    {waiting_count: length, limit: $limit, waiting_prs: map({task, pr, head})} as $det
    | {present: true, readable: true, observed_epoch: $obs, max_age_seconds: $max_age, target_scope: "per-PR-head"} as $prf
    | if length >= $limit then
        {status: "tripped", verdict_effect: "stop_dispatch", reason: "\(length) distinct PR heads waiting for CI/check admission (limit \($limit)): \([.[].task] | join(", "))", details: $det, proof: $prf}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det, proof: $prf}
      end
  '
}

eval_validation_cap() {  # <since_epoch> <now>
  local since=$1 now=$2 f runs_json="[]" row u h ce
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
      if ! jq -e '
        def sha40: type == "string" and test("^[0-9a-fA-F]{40}$");
        .schema == "firstmate-pr-review-ledger.v1"
        and (.url | type == "string" and length > 0)
        and (.current_head | sha40)
        and (.generations | type == "array" and length > 0)
        and (.generations[-1] | type == "object")
        and (.generations[-1].head | sha40)
        and (.generations[-1].head == .current_head)
        and (.generations[-1].risk | type == "object" and (.level == "low" or .level == "high"))
        and (.generations[-1].created_epoch | type == "number" and . >= 0 and floor == .)
      ' "$f" >/dev/null 2>&1; then
        cond_json unknown stop_dispatch "review ledger $(basename "$f") has incomplete or malformed current generation" '{}'
        return 0
      fi
      # Count high-stakes PRs whose validated current generation was created
      # during the night (PR-ready time, deduplicated by PR URL and head).
      row=$(jq -r --argjson since "$since" '
        .generations[-1] as $g
        | if $g.risk.level == "high" and $g.created_epoch >= $since then
            [.url, $g.head, ($g.created_epoch | tostring)] | @tsv
          else empty end
      ' "$f" 2>/dev/null) || {
        cond_json unknown stop_dispatch "failed to inspect review ledger $(basename "$f")" '{}'
        return 0
      }
      [ -n "$row" ] || continue
      IFS=$'\t' read -r u h ce <<EOF
$row
EOF
      runs_json=$(printf '%s\n' "$runs_json" | jq -c --arg url "$u" --arg head "$h" --argjson ep "$ce" '
        if any(.[]; .url == $url and .head == $head) then .
        else . + [{url: $url, head: $head, created_epoch: $ep}] end
      ')
    done
  fi
  # shellcheck disable=SC2016
  printf '%s\n' "$runs_json" | jq -c \
    --argjson cap "$VALIDATION_CAP" \
    --argjson since "$since" \
    --argjson now "$now" \
    --argjson max_age "$LIVE_INPUT_MAX_AGE" '
    {count: length, cap: $cap, since_epoch: $since, runs: .} as $det
    | {present: true, readable: true, observed_epoch: $now, max_age_seconds: $max_age, target_scope: "per-(url,head)"} as $prf
    | if length >= $cap then
        {status: "tripped", verdict_effect: "stop_validation", reason: "high-stakes validation cap reached (\(length) of \($cap) high-stakes PRs created tonight)", details: $det, proof: $prf}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det, proof: $prf}
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

  local key_rc=0 cur_key=""
  if [ -e "$hf" ] || [ -L "$hf" ]; then
    # Check explicit opt-out first; otherwise require a checked read of any
    # present config/supervision-host so an unreadable config never falls back
    # silently to the default model on a Claude primary.
    if [ -e "$CONFIG/supervision-host-off" ] || [ -L "$CONFIG/supervision-host-off" ]; then
      key_rc=3
    else
      if [ -e "$CONFIG/supervision-host" ] || [ -L "$CONFIG/supervision-host" ]; then
        if [ -L "$CONFIG/supervision-host" ] || [ ! -f "$CONFIG/supervision-host" ] \
          || [ ! -r "$CONFIG/supervision-host" ] || ! cat "$CONFIG/supervision-host" >/dev/null 2>&1; then
          cond_json unknown stop_dispatch "supervision-host config $CONFIG/supervision-host is unreadable or unsafe" '{}'
          return 0
        fi
      fi
      cur_key=$(
        # shellcheck source=bin/fm-wake-lib.sh
        . "$SCRIPT_DIR/fm-wake-lib.sh" >/dev/null 2>&1 || exit 1
        # shellcheck source=bin/fm-supervision-engine-lib.sh
        . "$SCRIPT_DIR/fm-supervision-engine-lib.sh" >/dev/null 2>&1 || exit 1
        fm_supervision_host_config "$CONFIG" "$(fm_supervision_host_primary)" || exit 3
        [ -z "${FM_SUPERVISION_ENGINE_PROBLEM:-}" ] || exit 2
        fm_supervision_host_health_key "$STATE"
      ) || key_rc=$?
    fi
  fi
  if { [ -e "$hf" ] || [ -L "$hf" ]; } && [ "$key_rc" -ne 3 ]; then
    if [ -L "$hf" ] || [ ! -f "$hf" ] || [ ! -r "$hf" ]; then
      cond_json unknown stop_dispatch "supervision-host health file $hf is unreadable or unsafe" '{}'
      return 0
    fi
    local f_key cd_val ra_val err_val
    f_key=$(sed -n 's/^key=//p' "$hf" 2>/dev/null | head -1)
    cd_val=$(sed -n 's/^cooldown=//p' "$hf" 2>/dev/null | head -1)
    ra_val=$(sed -n 's/^retry_after=//p' "$hf" 2>/dev/null | head -1)
    err_val=$(sed -n 's/^errors=//p' "$hf" 2>/dev/null | head -1)
    if [ -z "$f_key" ] || ! is_uint "$cd_val" || ! is_uint "$ra_val" || { [ -n "$err_val" ] && ! is_uint "$err_val"; }; then
      cond_json unknown stop_dispatch "supervision-host health file $hf has malformed fields" '{}'
      return 0
    fi
    if [ "$key_rc" -ne 0 ]; then
      cond_json unknown stop_dispatch "supervision-host health file $hf is present but current engine key could not be resolved" '{}'
      return 0
    fi
    if [ "$f_key" = "$cur_key" ] && [ "$cd_val" -gt 0 ]; then
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
  local prf
  prf=$(proof_json true true "$now" "$LIVE_INPUT_MAX_AGE" "home:supervision-engine")
  if [ "$wake_stalled" -eq 1 ] || [ "$latch_stalled" -eq 1 ]; then
    cond_json tripped stop_dispatch "supervision stall: $reasons" "$details" "$prf"
  else
    cond_json ok continue "" "$details" "$prf"
  fi
}

eval_hc_core() {  # <now> <since_epoch>
  local now=$1 since=$2 active_state target_json=null base_json=null session="" socket="" cur_json
  local hc_obs_epoch=$now hc_max_age=$LIVE_INPUT_MAX_AGE hc_scope="backend:non-hc"
  if [ -e "$ACTIVE_FILE" ] || [ -L "$ACTIVE_FILE" ]; then
    if [ -L "$ACTIVE_FILE" ] || [ ! -f "$ACTIVE_FILE" ] || [ ! -r "$ACTIVE_FILE" ]; then
      cond_json unknown stop_dispatch "state/night-active.json is unreadable or unsafe" '{}'
      return 0
    fi
    # Validate backend, hc_target, and hc_baseline as a unit so a partial or
    # corrupted active record can never fall back to ambient routing or
    # masquerade as a non-hc night.
    active_state=$(jq -r '
      def valid_session: type == "string" and test("^[A-Za-z0-9._][A-Za-z0-9._-]*$");
      def valid_target:
        type == "object" and has("session") and has("socket")
        and (.session | valid_session)
        and (.socket == null or (.socket | type == "string" and length > 0));
      def valid_baseline:
        . == null or (
          type == "object"
          and (.pid | type == "number" and . > 0 and floor == .)
          and (.uptime_ms | type == "number" and . >= 0)
          and (.started_epoch | type == "number" and . >= 0 and floor == .)
          and (.core_id | type == "string")
          and (.holder_instance | type == "string")
        );
      if .schema != "fm-night-active.v1" then
        "bad_active"
      elif (.started_epoch | type != "number" or . < 0 or floor != .) then
        "bad_active"
      elif (has("backend") | not) or (.backend | type != "string" or length == 0) then
        "bad_backend"
      elif .backend == "hc" then
        if (has("hc_target") | not) or (.hc_target | valid_target | not) then
          "bad_target"
        elif (has("hc_baseline") | not) or (.hc_baseline | valid_baseline | not) then
          "bad_baseline"
        else
          "hc"
        end
      else
        if (.hc_target != null) or (.hc_baseline != null) then
          "bad_non_hc"
        else
          "non_hc"
        end
      end
    ' "$ACTIVE_FILE" 2>/dev/null) || active_state="bad_active"
    case "$active_state" in
      bad_active)
        cond_json unknown stop_dispatch "state/night-active.json is malformed" '{}'
        return 0
        ;;
      bad_backend)
        cond_json unknown stop_dispatch "state/night-active.json is missing or has invalid backend" '{}'
        return 0
        ;;
      bad_target)
        cond_json unknown stop_dispatch "saved hc_target in state/night-active.json is missing or malformed" '{}'
        return 0
        ;;
      bad_baseline)
        cond_json unknown stop_dispatch "saved hc_baseline in state/night-active.json is malformed" '{}'
        return 0
        ;;
      bad_non_hc)
        cond_json unknown stop_dispatch "state/night-active.json has hc fields under a non-hc backend" '{}'
        return 0
        ;;
      hc)
        target_json=$(jq -c '.hc_target' "$ACTIVE_FILE" 2>/dev/null) || {
          cond_json unknown stop_dispatch "could not read saved hc_target from state/night-active.json" '{}'
          return 0
        }
        base_json=$(jq -c '.hc_baseline' "$ACTIVE_FILE" 2>/dev/null) || {
          cond_json unknown stop_dispatch "could not read saved hc_baseline from state/night-active.json" '{}'
          return 0
        }
        hc_obs_epoch=$(jq -r '.started_epoch' "$ACTIVE_FILE" 2>/dev/null) || hc_obs_epoch=""
        if ! is_uint "$hc_obs_epoch"; then
          cond_json unknown stop_dispatch "state/night-active.json has invalid started_epoch for hc target" '{}'
          return 0
        fi
        hc_max_age=$HC_TARGET_MAX_AGE
        session=$(printf '%s\n' "$target_json" | jq -r '.session')
        socket=$(printf '%s\n' "$target_json" | jq -r '.socket // ""')
        hc_scope="hc:$session"
        ;;
      non_hc)
        if ! resolve_hc_target; then
          cond_json unknown stop_dispatch "$HC_TARGET_ERROR" '{}'
          return 0
        fi
        if [ "$HC_TARGET_RESOLVED_BACKEND" != "hc" ]; then
          cond_json not_applicable continue "" '{}' \
            "$(proof_json true true "$now" "$LIVE_INPUT_MAX_AGE" "backend:$HC_TARGET_RESOLVED_BACKEND")"
          return 0
        fi
        session=$HC_TARGET_SESSION
        socket=$HC_TARGET_SOCKET
        target_json=$(jq -cn --arg s "$session" --arg sock "$socket" \
          '{session: $s, socket: (if $sock == "" then null else $sock end)}')
        base_json=null
        hc_obs_epoch=$now
        hc_max_age=$HC_TARGET_MAX_AGE
        hc_scope="hc:$session"
        ;;
    esac
  else
    if ! resolve_hc_target; then
      cond_json unknown stop_dispatch "$HC_TARGET_ERROR" '{}'
      return 0
    fi
    if [ "$HC_TARGET_RESOLVED_BACKEND" != "hc" ]; then
      cond_json not_applicable continue "" '{}' \
        "$(proof_json true true "$now" "$LIVE_INPUT_MAX_AGE" "backend:$HC_TARGET_RESOLVED_BACKEND")"
      return 0
    fi
    session=$HC_TARGET_SESSION
    socket=$HC_TARGET_SOCKET
    target_json=$(jq -cn --arg s "$session" --arg sock "$socket" \
      '{session: $s, socket: (if $sock == "" then null else $sock end)}')
    base_json=null
    hc_obs_epoch=$now
    hc_max_age=$HC_TARGET_MAX_AGE
    hc_scope="hc:$session"
  fi
  if ! cur_json=$(read_hc_status_json "$now" "$session" "$socket"); then
    cond_json unknown stop_dispatch "herdr-core server status could not be read for session '$session'" \
      "$(jq -cn --argjson target "$target_json" '{target: $target}')"
    return 0
  fi
  # shellcheck disable=SC2016
  jq -cn \
    --argjson target "$target_json" \
    --argjson cur "$cur_json" \
    --argjson base "$base_json" \
    --argjson since "$since" \
    --argjson obs "$hc_obs_epoch" \
    --argjson max_age "$hc_max_age" \
    --arg scope "$hc_scope" '
    (if $base != null and ($base.pid | type == "number") and $cur.pid != $base.pid then
       "hc core pid changed (\($base.pid) -> \($cur.pid))"
     elif $base != null and (($base.holder_instance // "") != "") and (($cur.holder_instance // "") != "") and $cur.holder_instance != $base.holder_instance then
       "hc core holder instance changed (\($base.holder_instance) -> \($cur.holder_instance))"
     elif $base != null and (($base.core_id // "") != "") and (($cur.core_id // "") != "") and $cur.core_id != $base.core_id then
       "hc core id changed (\($base.core_id) -> \($cur.core_id))"
     elif $base == null and $cur.started_epoch > ($since + 5) then
       "hc core started after night began (started_epoch \($cur.started_epoch) > night_start \($since), uptime \($cur.uptime_ms)ms)"
     else "" end) as $restart_reason
    | {target: $target, baseline: $base, current: $cur} as $det
    | {present: true, readable: true, observed_epoch: $obs, max_age_seconds: $max_age, target_scope: $scope} as $prf
    | if $restart_reason != "" then
        {status: "tripped", verdict_effect: "end_night", reason: "hc core restarted during the night: \($restart_reason)", details: $det, proof: $prf}
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: $det, proof: $prf}
      end
  '
}

eval_host_load() {  # <now>
  local now=$1 os load1="" prev_since=null max_gap=$((HIGH_LOAD_MINUTES * 120))
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
    prev_since=$(jq -c --argjson now "$now" --argjson gap "$max_gap" '
      if (.checked_epoch | type == "number") and .checked_epoch <= $now and ($now - .checked_epoch) <= $gap then
        (.conditions.host_load.details.high_load_since_epoch // null)
        | if (type == "number" and . <= $now) then . else null end
      else null end
    ' "$VERDICT_FILE" 2>/dev/null) || prev_since=null
    [ -n "$prev_since" ] || prev_since=null
  fi
  # shellcheck disable=SC2016
  jq -cn \
    --arg load1 "$load1" \
    --arg thresh "$HIGH_LOAD_THRESHOLD" \
    --argjson mins "$HIGH_LOAD_MINUTES" \
    --argjson now "$now" \
    --argjson prev_since "$prev_since" \
    --argjson max_age "$LIVE_INPUT_MAX_AGE" '
    ($load1 | tonumber) as $l
    | ($thresh | tonumber) as $t
    | ($mins * 60) as $dur_limit
    | {present: true, readable: true, observed_epoch: $now, max_age_seconds: $max_age, target_scope: "host:loadavg"} as $prf
    | if $l > $t then
        ($prev_since // $now) as $since
        | ($now - $since) as $elapsed
        | {load1: $l, threshold: $t, limit_seconds: $dur_limit, high_load_since_epoch: $since, elapsed_seconds: $elapsed} as $det
        | if $elapsed >= $dur_limit then
            {status: "tripped", verdict_effect: "stop_dispatch", reason: "host 1-minute load (\($l)) stayed above \($t) for \($elapsed)s (limit \($dur_limit)s)", details: $det, proof: $prf}
          else
            {status: "ok", verdict_effect: "continue", reason: "", details: $det, proof: $prf}
          end
      else
        {status: "ok", verdict_effect: "continue", reason: "", details: {load1: $l, threshold: $t, limit_seconds: $dur_limit, high_load_since_epoch: null, elapsed_seconds: 0}, proof: $prf}
      end
  '
}

# --- Durable stop record (single owner path) --------------------------------
write_stop_record() {  # <verdict_json> <now> <iso>
  local verdict_json=$1 now=$2 iso=$3
  local first_epoch=$now first_at=$iso prev_stall=null prev_history="[]" prev_dev_tripped=false doc
  if [ -f "$STOP_FILE" ] && [ ! -L "$STOP_FILE" ] && [ -r "$STOP_FILE" ]; then
    local pe pa ps ph pd
    pe=$(jq -r 'if .schema == "fm-night-stop.v1" and (.first_tripped_epoch | type == "number") then .first_tripped_epoch else empty end' "$STOP_FILE" 2>/dev/null) || pe=""
    pa=$(jq -r 'if .schema == "fm-night-stop.v1" and (.first_tripped_at | type == "string") then .first_tripped_at else empty end' "$STOP_FILE" 2>/dev/null) || pa=""
    ps=$(jq -c 'if .schema == "fm-night-stop.v1" and (.stall_since_epoch | type == "number") then .stall_since_epoch else null end' "$STOP_FILE" 2>/dev/null) || ps=null
    ph=$(jq -c 'if .schema == "fm-night-stop.v1" and (.history | type == "array") then .history else [] end' "$STOP_FILE" 2>/dev/null) || ph="[]"
    pd=$(jq -r '.schema == "fm-night-stop.v1" and any((.tripped // [])[]; .condition == "dev_health" and .status == "tripped")' "$STOP_FILE" 2>/dev/null) || pd=false
    [ -z "$pe" ] || first_epoch=$pe
    [ -z "$pa" ] || first_at=$pa
    prev_stall=${ps:-null}
    prev_history=${ph:-[]}
    [ "$pd" = true ] && prev_dev_tripped=true
  fi
  doc=$(printf '%s\n' "$verdict_json" | jq \
    --argjson first_epoch "$first_epoch" \
    --arg first_at "$first_at" \
    --argjson now "$now" \
    --arg iso "$iso" \
    --argjson prev_stall "$prev_stall" \
    --argjson prev_history "$prev_history" \
    --argjson prev_dev_tripped "$prev_dev_tripped" '
    (if any(.latched[]; .condition == "supervision_stall") then
       ([$prev_stall, .conditions.supervision_stall.details.stall_since_epoch?] | map(select(type == "number")) | min)
     else $prev_stall end) as $stall_since
    | (.conditions.dev_health) as $dev
    | (if $dev.status != "tripped" then $prev_history
       elif $prev_dev_tripped and (([$prev_history[] | select(.condition == "dev_health")] | last) // {}).reason == $dev.reason then
         ([$prev_history | to_entries[] | select(.value.condition == "dev_health") | .key] | last) as $i
         | $prev_history | .[$i].last_tripped_epoch = $now | .[$i].last_tripped_at = $iso
       else
         $prev_history + [{condition: "dev_health", verdict_effect: $dev.verdict_effect, reason: $dev.reason,
                           first_tripped_epoch: $now, first_tripped_at: $iso, last_tripped_epoch: $now, last_tripped_at: $iso}]
       end) as $history
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
        latched: .latched,
        history: $history,
        stall_since_epoch: $stall_since,
        core_restarted: any(.latched[]; .condition == "hc_core"),
        reserve_flag: .reserve_flag
      }
  ') || return 1
  atomic_write_json "$STOP_FILE" "$doc"
}

render_human_verdict() {  # <verdict_json_file>
  jq -r '
    "night-check: verdict=\(.verdict) (\(.verdict_label)) dispatch=\(.allow.dispatch) claude=\(.allow.claude) merge=\(.allow.merge) validation=\(.allow.validation) two_hour_default=\(.allow.two_hour_default)",
    (.tripped[] | "  - \(.condition) (\(.status) -> \(.verdict_effect)): \(.reason)"),
    ((.warnings // [])[] | "  warning: \(.)")
  ' "$1"
}

PRIOR_LATCHED="[]"
STOP_RECORD_BAD=0
STOP_RECORD_BAD_REASON=""
load_prior_latched_json() {  # <night_started> <stop_expected> -> sets PRIOR_LATCHED, STOP_RECORD_BAD, STOP_RECORD_BAD_REASON
  local night_started=$1 stop_expected=$2 out
  PRIOR_LATCHED="[]"
  STOP_RECORD_BAD=0
  STOP_RECORD_BAD_REASON=""
  if [ ! -e "$STOP_FILE" ] && [ ! -L "$STOP_FILE" ]; then
    if [ "$stop_expected" = true ]; then
      STOP_RECORD_BAD=1
      STOP_RECORD_BAD_REASON="expected state/night-stop.json for this night is missing, so earlier latched stops are unknown"
    fi
    return 0
  fi
  if [ -f "$STOP_FILE" ] && [ ! -L "$STOP_FILE" ] && [ -r "$STOP_FILE" ] \
    && out=$(jq -c --argjson ns "$night_started" '
      def valid_latch:
        type == "object"
        and (.condition == "failure_streak" or .condition == "supervision_stall" or .condition == "hc_core")
        and (.verdict_effect == "stop_dispatch" or .verdict_effect == "end_night")
        and (.reason | type == "string" and length > 0)
        and (.latched_epoch | type == "number" and . >= 0 and floor == .)
        and (.latched_at | type == "string" and length > 0);
      if .schema != "fm-night-stop.v1" then
        error("bad schema")
      elif .night_started_epoch != $ns then
        error("wrong night")
      elif (.latched | type != "array") or (all(.latched[]; valid_latch) | not) then
        error("bad latched")
      else
        .latched
      end
    ' "$STOP_FILE" 2>/dev/null) \
    && [ -n "$out" ]; then
    PRIOR_LATCHED=$out
    return 0
  fi
  STOP_RECORD_BAD=1
  STOP_RECORD_BAD_REASON="state/night-stop.json is unreadable, corrupt, or belongs to a different night, so earlier latched stops are unknown"
  return 0
}

# --- Single stop-by-default verdict function --------------------------------
# evaluate_night_verdict is the sole owner of all allow/stop decisions.
# Default is STOP (`stop_dispatch`, all allow.* = false). Work is allowed only
# when every required input is proven present, readable, within its explicit
# maximum allowed age, on its target scope/branch, and ok (or not_applicable
# for hc_core on a proven non-hc backend). Any missing, unreadable, malformed,
# stale, wrong-branch, or unknown input overrides to `unknown` (`stop_dispatch`)
# and blocks dispatch, Claude work, merges, validations, and two-hour defaults.
evaluate_night_verdict() {
  local now=$1 iso=$2 night_active=$3 active_bad=$4 night_started=$5
  local stop_record_bad=$6 stop_record_bad_reason=$7
  local c_window=$8 c_quota=$9 c_gh=${10} c_streak=${11} c_dev=${12}
  local c_cm=${13} c_val=${14} c_stall=${15} c_hc=${16} c_load=${17}
  local prior_latched=${18} rf_configured=${19} rf_path=${20}
  jq -n \
    --argjson now "$now" \
    --arg iso "$iso" \
    --argjson night_active "$night_active" \
    --argjson active_bad "$active_bad" \
    --argjson night_started "$night_started" \
    --argjson stop_record_bad "$stop_record_bad" \
    --arg stop_record_bad_reason "$stop_record_bad_reason" \
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
    --argjson prior_latched "$prior_latched" \
    --argjson rf_configured "$rf_configured" \
    --arg rf_path "$rf_path" \
    --argjson live_max_age "$LIVE_INPUT_MAX_AGE" \
    --argjson quota_max_age "$QUOTA_MAX_AGE" \
    --argjson check_max_age "$CHECK_EVIDENCE_MAX_AGE" \
    --argjson hc_max_age "$HC_TARGET_MAX_AGE" \
    '
    def rank:
      if . == "end_night" then 4
      elif . == "stop_dispatch" then 3
      elif . == "stop_claude" then 2
      elif . == "stop_validation" then 1
      else 0 end;
    def verdict_label:
      if . == "end_night" then "end the night"
      elif . == "stop_dispatch" then "stop new dispatch"
      elif . == "stop_claude" then "stop new Claude work"
      elif . == "stop_validation" then "stop new validations"
      else "continue" end;
    def enforce_proof($name; $cond; $max_age):
      if ($cond | type) != "object" then
        {status: "unknown", verdict_effect: "stop_dispatch", reason: "\($name): missing or malformed condition result", details: {}, proof: {present: false, readable: false, observed_epoch: null, max_age_seconds: $max_age, target_scope: null}}
      elif ($cond.status != "ok" and $cond.status != "not_applicable" and $cond.status != "tripped" and $cond.status != "unknown") then
        $cond + {status: "unknown", verdict_effect: "stop_dispatch", reason: "\($name): unrecognized condition status"}
      elif $cond.status == "not_applicable" and $name != "hc_core" then
        $cond + {status: "unknown", verdict_effect: "stop_dispatch", reason: "\($name): required input cannot be not_applicable"}
      elif $cond.status == "ok" or $cond.status == "not_applicable" then
        ($cond.proof // null) as $p
        | if ($p | type) != "object"
             or $p.present != true
             or $p.readable != true
             or ($p.observed_epoch | type != "number" or . < 0 or floor != .) then
            $cond + {status: "unknown", verdict_effect: "stop_dispatch", reason: "\($name): required input lacks valid present/readable observation proof"}
          elif $p.observed_epoch > ($now + 60) then
            $cond + {status: "unknown", verdict_effect: "stop_dispatch", reason: "\($name): observation timestamp \($p.observed_epoch) is in the future relative to \($now)"}
          elif ($now - $p.observed_epoch) > $max_age then
            $cond + {status: "unknown", verdict_effect: "stop_dispatch", reason: "\($name): evidence is stale (age \($now - $p.observed_epoch)s exceeds allowed \($max_age)s)"}
          else
            $cond
          end
      elif $cond.status == "unknown" then
        $cond + {verdict_effect: "stop_dispatch"}
      else
        $cond
      end;
    ["failure_streak", "supervision_stall", "hc_core"] as $events
    | ["night_window", "claude_quota", "github_api", "failure_streak", "dev_health",
       "check_machine", "validation_cap", "supervision_stall", "hc_core", "host_load"] as $required
    | {
      night_window:      enforce_proof("night_window";      $c_window; $live_max_age),
      claude_quota:      enforce_proof("claude_quota";      $c_quota;  $quota_max_age),
      github_api:        enforce_proof("github_api";        $c_gh;     $live_max_age),
      failure_streak:    enforce_proof("failure_streak";    $c_streak; $live_max_age),
      dev_health:        enforce_proof("dev_health";        $c_dev;    $live_max_age),
      check_machine:     enforce_proof("check_machine";     $c_cm;     $check_max_age),
      validation_cap:    enforce_proof("validation_cap";    $c_val;    $live_max_age),
      supervision_stall: enforce_proof("supervision_stall"; $c_stall;  $live_max_age),
      hc_core:           enforce_proof("hc_core";           $c_hc;     $hc_max_age),
      host_load:         enforce_proof("host_load";         $c_load;   $live_max_age)
    } as $conds
    | (if $night_active and $active_bad == 0 then
         $prior_latched
         + [ $conds | to_entries[]
             | select(.key as $k | any($events[]; . == $k))
             | select(.value.status == "tripped")
             | select(.key as $k | any($prior_latched[]; .condition == $k) | not)
             | {condition: .key, verdict_effect: .value.verdict_effect, reason: .value.reason, latched_epoch: $now, latched_at: $iso} ]
       else [] end) as $latched
    | ([ $conds | to_entries[] | select(.value.status == "tripped" or .value.status == "unknown")
         | {condition: .key, status: .value.status, verdict_effect: .value.verdict_effect, reason: .value.reason} ]
       + (if $stop_record_bad == 1 then
            [{condition: "night_stop_record", status: "unknown", verdict_effect: "stop_dispatch", reason: (if $stop_record_bad_reason != "" then $stop_record_bad_reason else "state/night-stop.json is unreadable or corrupt, so earlier latched stops are unknown" end)}]
          else [] end)
       + [ $latched[] | select(($conds[.condition].status // "") != "tripped")
           | {condition: .condition, status: "latched", verdict_effect: .verdict_effect, reason: "latched at \(.latched_at): \(.reason)"} ]) as $tripped
    # Default posture is STOP; continue is granted only when every required input
    # is proven ok (or hc_core not_applicable) and zero stops or unknowns exist.
    | (all($required[]; $conds[.].status == "ok" or (. == "hc_core" and $conds[.].status == "not_applicable"))
       and ($tripped | length) == 0 and $stop_record_bad == 0 and $active_bad == 0) as $all_proven_ok
    | (any($tripped[]; .status == "unknown") or $stop_record_bad == 1 or $active_bad == 1) as $any_unknown
    | (if $all_proven_ok then "continue"
       elif ($tripped | length) > 0 then ($tripped | max_by(.verdict_effect | rank) | .verdict_effect)
       else "stop_dispatch" end) as $verdict
    | ($any_unknown or any($tripped[]; .condition == "dev_health" or .condition == "supervision_stall" or .condition == "hc_core" or .condition == "night_stop_record")) as $health_blocked
    | (($any_unknown | not) and ($verdict == "continue" or $verdict == "stop_validation" or $verdict == "stop_claude")) as $allow_dispatch
    | (($any_unknown | not) and ($verdict == "continue" or $verdict == "stop_validation")) as $allow_claude
    | (($any_unknown | not) and $verdict != "end_night" and ($health_blocked | not)) as $allow_merge
    | $all_proven_ok as $allow_validation
    | ($night_active and $active_bad == 0 and $allow_dispatch and $allow_merge and ($health_blocked | not)) as $allow_default
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
        latched: $latched,
        warnings: ((if $rf_configured then []
                    else ["config/lane-capacity names no reserve-flag, so stop_dispatch cannot be enforced through bin/fm-capacity.sh admission"] end)
                   + (if ($c_dev.details.cache_warning // "") != "" then [$c_dev.details.cache_warning] else [] end)),
        conditions: $conds,
        reserve_flag: {
          configured: $rf_configured,
          path: (if $rf_path == "" then null else $rf_path end),
          state: "not_configured"
        },
        stop_record_path: null
      }
  '
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

  local now iso night_active=false night_started=null active_bad=0 stop_expected=false
  now=$(now_epoch)
  iso=$(epoch_to_iso "$now")

  parse_night_config || true

  if [ -e "$ACTIVE_FILE" ] || [ -L "$ACTIVE_FILE" ]; then
    if [ -f "$ACTIVE_FILE" ] && [ ! -L "$ACTIVE_FILE" ] && [ -r "$ACTIVE_FILE" ] \
      && jq -e '
        .schema == "fm-night-active.v1"
        and (.started_epoch | type == "number" and . >= 0 and floor == .)
        and (.created_reserve_flags == null or (.created_reserve_flags | type == "array"))
        and (.stop_record_expected == null or (.stop_record_expected | type == "boolean"))
      ' "$ACTIVE_FILE" >/dev/null 2>&1; then
      night_active=true
      night_started=$(jq -r '.started_epoch' "$ACTIVE_FILE")
      if jq -e '(.stop_record_expected == true) or ((.created_reserve_flags // []) | length > 0)' "$ACTIVE_FILE" >/dev/null 2>&1; then
        stop_expected=true
      fi
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
  c_gh=$(eval_github_api "$now")
  c_streak=$(eval_failure_streak "$since_epoch" "$night_active" "$now")
  c_dev=$(eval_dev_health "$now" "$since_epoch")
  c_cm=$(eval_check_machine "$now")
  c_val=$(eval_validation_cap "$since_epoch" "$now")
  c_stall=$(eval_supervision_stall "$now")
  c_hc=$(eval_hc_core "$now" "$since_epoch")
  c_load=$(eval_host_load "$now")

  local prior_latched="[]" stop_record_bad=0 stop_record_bad_reason=""
  if [ "$night_active" = true ] && [ "$active_bad" -eq 0 ]; then
    load_prior_latched_json "$night_started" "$stop_expected"
    prior_latched=$PRIOR_LATCHED
    stop_record_bad=$STOP_RECORD_BAD
    stop_record_bad_reason=$STOP_RECORD_BAD_REASON
  fi

  local rf_configured=false rf_path=""
  if rf_path=$(first_lane_reserve_flag); then
    rf_configured=true
  else
    rf_path=""
  fi

  local verdict_doc
  verdict_doc=$(evaluate_night_verdict \
    "$now" "$iso" "$night_active" "$active_bad" "$night_started" \
    "$stop_record_bad" "$stop_record_bad_reason" \
    "$c_window" "$c_quota" "$c_gh" "$c_streak" "$c_dev" \
    "$c_cm" "$c_val" "$c_stall" "$c_hc" "$c_load" \
    "$prior_latched" "$rf_configured" "$rf_path") || die "could not assemble verdict document"

  local final_verdict latched_count latched_summary rf_state="not_configured" rf_token="" rf_warn=""
  final_verdict=$(printf '%s\n' "$verdict_doc" | jq -r '.verdict')
  latched_count=$(printf '%s\n' "$verdict_doc" | jq -r '.latched | length')
  latched_summary=$(printf '%s\n' "$verdict_doc" | jq -r '[.latched[].reason] | join("; ")')

  if [ "$rf_configured" = "true" ]; then
    rf_state=$(reserve_flag_state "$rf_path")
    if [ "$latched_count" -gt 0 ] && [ "$stop_record_bad" -eq 0 ] && [ "$rf_state" = absent ]; then
      rf_token="fm-night-${now}-$$-${RANDOM}"
      if create_lane_reserve_flag "$rf_path" "$rf_token" "$final_verdict" "$iso" "$latched_summary"; then
        if ! record_created_reserve_flag "$rf_path" "$rf_token"; then
          if reserve_flag_matches_token "$rf_path" "$rf_token"; then
            if rm -f -- "$rf_path" 2>/dev/null; then
              rf_warn="could not record reserve-flag ownership in state/night-active.json; rolled back newly created reserve-flag at $rf_path so stop_dispatch is not enforced through admission"
            else
              rf_warn="could not record reserve-flag ownership in state/night-active.json and rollback of $rf_path failed"
            fi
          else
            rf_warn="could not record reserve-flag ownership in state/night-active.json; flag at $rf_path was modified before rollback and left untouched"
          fi
          printf 'fm-night-check: warning: %s\n' "$rf_warn" >&2
        fi
      else
        rf_warn="could not create reserve-flag at $rf_path, so stop_dispatch is not enforced through admission"
        printf 'fm-night-check: warning: %s\n' "$rf_warn" >&2
      fi
      rf_state=$(reserve_flag_state "$rf_path")
    fi
  fi

  local record_stop=0 dev_tripped
  dev_tripped=$(printf '%s\n' "$verdict_doc" | jq -r '.conditions.dev_health.status == "tripped"')
  if [ "$stop_record_bad" -eq 0 ] && [ "$night_active" = true ] && [ "$active_bad" -eq 0 ] \
    && { [ "$latched_count" -gt 0 ] || [ "$dev_tripped" = true ] || [ -e "$STOP_FILE" ]; }; then
    record_stop=1
  fi

  local stop_path_json="null"
  if [ "$record_stop" -eq 1 ]; then
    stop_path_json=$(jq -cn --arg p "$STOP_FILE" '$p')
  fi

  verdict_doc=$(printf '%s\n' "$verdict_doc" | jq \
    --arg rf_state "$rf_state" \
    --arg rf_warn "$rf_warn" \
    --argjson stop_path "$stop_path_json" \
    '.reserve_flag.state = $rf_state
     | .stop_record_path = $stop_path
     | if $rf_warn != "" then .warnings = (.warnings + [$rf_warn]) else . end')

  if [ "$record_stop" -eq 1 ]; then
    write_stop_record "$verdict_doc" "$now" "$iso" || die "could not write $STOP_FILE"
    if [ "$latched_count" -gt 0 ]; then
      mark_stop_record_expected || true
    fi
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
  hc-guard)
    shift
    [ "$#" -eq 0 ] || die_usage "hc-guard takes no arguments"
    cmd_hc_guard
    ;;
  *)
    die_usage "unknown subcommand '$cmd'"
    ;;
esac
