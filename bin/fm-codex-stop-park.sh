#!/usr/bin/env bash
# Codex Stop-hook watcher park for a firstmate PRIMARY session.
#
# Usage: Codex invokes this script from the tracked .codex/hooks.json Stop
# registration. It is not an operator command.
#
# Codex waits for synchronous Stop hooks. While supervision is needed, this
# hook keeps bin/fm-watch-arm.sh in its own process tree until the watcher
# returns an actionable wake, then exits 2 with that wake on stderr. Codex turns
# the stderr text into a continuation prompt in the same session. The watcher
# therefore has a verified return path to its supervisor; a fresh heartbeat by
# itself is never treated as continuity proof.
#
# A newer Stop invocation supersedes an older park through the home-scoped
# owner record. The arm singleton prevents overlapping watcher cycles while the
# owner sequence prevents an older hook from delivering a duplicate wake.
# The watcher may stay quiet indefinitely, but Codex gives the synchronous hook
# a finite timeout. The park therefore returns one scheduled continuation every
# six hours, well before the tracked 24-hour hook timeout, so the next Stop can
# establish a fresh callback instead of silently losing the old one to timeout.
# Away or quiet mode, no remaining supervision need, a foreign live session
# owner, child worktrees, malformed input, and cancellation all stand down.
# A genuine arm failure starts a bounded park-owned repair episode, independent
# of stop_hook_active, because that field is also true after real watcher wakes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER="$STATE/.codex-park-owner"
OWNER_LOCK="$STATE/.codex-park-owner.lock"
POLL=${FM_CODEX_PARK_POLL:-1}
HOOK_TIMEOUT_SECONDS=${FM_CODEX_STOP_TIMEOUT_SECONDS:-86400}
LOCK_ATTEMPTS=${FM_CODEX_PARK_LOCK_ATTEMPTS:-50}
FAILURE_BUDGET=${FM_CODEX_PARK_FAILURE_BUDGET:-3}
FAILURE_FILE="$STATE/.codex-park-failures"
case "$POLL" in ''|*[!0-9]*|0) POLL=1 ;; esac
case "$HOOK_TIMEOUT_SECONDS" in ''|*[!0-9]*|0) HOOK_TIMEOUT_SECONDS=86400 ;; esac
RENEW_DEFAULT=$((HOOK_TIMEOUT_SECONDS / 4))
[ "$RENEW_DEFAULT" -gt 0 ] || RENEW_DEFAULT=21600
RENEW_SECONDS=${FM_CODEX_PARK_RENEW_SECONDS:-$RENEW_DEFAULT}
case "$RENEW_SECONDS" in ''|*[!0-9]*|0) RENEW_SECONDS=$RENEW_DEFAULT ;; esac
[ "$RENEW_SECONDS" -lt "$HOOK_TIMEOUT_SECONDS" ] || RENEW_SECONDS=$RENEW_DEFAULT
case "$LOCK_ATTEMPTS" in ''|*[!0-9]*|0) LOCK_ATTEMPTS=50 ;; esac
case "$FAILURE_BUDGET" in ''|*[!0-9]*|0) FAILURE_BUDGET=3 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -e '
  type == "object"
  and (.hook_event_name == "Stop")
  and ((.stop_hook_active // false) | type == "boolean")
' >/dev/null 2>&1 || exit 0

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

lock_acquire_bounded() { # <lock>
  local lock=$1 attempt=0
  while [ "$attempt" -lt "$LOCK_ATTEMPTS" ]; do
    fm_lock_try_acquire "$lock" && return 0
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$LOCK_ATTEMPTS" ] && sleep 0.1
  done
  return 1
}

claim_park() {
  local seq tmp
  lock_acquire_bounded "$OWNER_LOCK" || return 1
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  PARK_SEQ=$((seq + 1))
  tmp="$OWNER.tmp.${BASHPID:-$$}"
  if ! printf 'seq=%s pid=%s updated_at=%s\n' "$PARK_SEQ" "${BASHPID:-$$}" "$(date +%s)" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$OWNER" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$OWNER_LOCK"
}

park_still_ours() {
  local seq
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  [ "$seq" = "$PARK_SEQ" ]
}

current_session_still_ours() {
  local owner
  owner=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$owner" = "$OWNER_ID" ] || return 1
  fm_session_lock_owned_by_self "$STATE"
}

emit_continuation() { # <kind> <body>
  local kind=$1 body=$2 encoded
  fm_operational_input_encode "$kind" "$body" encoded || exit 0
  lock_acquire_bounded "$OWNER_LOCK" || exit 0
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    exit 0
  fi
  printf '%s\n' "$encoded" >&2
  fm_lock_release "$OWNER_LOCK"
  exit 2
}

failure_episode_reset() {
  lock_acquire_bounded "$OWNER_LOCK" || return 1
  if park_still_ours && current_session_still_ours; then
    rm -f "$FAILURE_FILE" 2>/dev/null || true
  fi
  fm_lock_release "$OWNER_LOCK"
}

handle_park_failure() {
  local count failure_owner
  if ! lock_acquire_bounded "$OWNER_LOCK"; then
    printf '{"systemMessage":"FIRSTMATE CODEX WATCHER PARK FAILED: the failure episode lock could not be acquired, so this Stop cannot safely schedule another automatic continuation."}\n'
    exit 0
  fi
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    exit 0
  fi
  failure_owner=$(sed -n 's/^owner=\([0-9][0-9]*\)$/\1/p' "$FAILURE_FILE" 2>/dev/null || true)
  count=$(sed -n 's/^count=\([0-9][0-9]*\)$/\1/p' "$FAILURE_FILE" 2>/dev/null || true)
  [ "$failure_owner" = "$OWNER_ID" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  if ! printf 'owner=%s\ncount=%s\n' "$OWNER_ID" "$count" > "$FAILURE_FILE" 2>/dev/null; then
    fm_lock_release "$OWNER_LOCK"
    printf '{"systemMessage":"FIRSTMATE CODEX WATCHER PARK FAILED: the bounded failure episode could not be persisted, so this Stop cannot safely schedule another automatic continuation."}\n'
    exit 0
  fi
  fm_lock_release "$OWNER_LOCK"

  if [ "$count" -le "$FAILURE_BUDGET" ]; then
    emit_continuation turn-end-guard "FIRSTMATE CODEX WATCHER PARK FAILED - supervision remains required, but the synchronous watcher arm closed without an actionable wake.

This is repair attempt $count of $FAILURE_BUDGET for the current failure episode. Inspect the watcher failure, repair supervision, and let the turn end normally; the next Stop retries the park even when stop_hook_active is true. Do not launch bin/fm-watch-arm.sh from the model."
  fi

  printf '{"systemMessage":"FIRSTMATE CODEX WATCHER PARK FAILURE BUDGET EXHAUSTED: supervision is still required after %s consecutive failed park attempts; automatic Stop continuations are now bounded."}\n' "$FAILURE_BUDGET"
  exit 0
}

# Only the lock-owning primary may park. Session start owns stale lock recovery;
# this hook never steals from a live session or guesses through uncertainty.
if ! fm_session_lock_owned_by_self "$STATE"; then
  if fm_session_lock_foreign_owner_live "$STATE"; then
    printf '{"systemMessage":"FIRSTMATE SUPERVISION IS OWNED BY ANOTHER LIVE SESSION: this read-only Codex session cannot arm or repair the watcher. The lock-owning session remains responsible for supervision."}\n'
  fi
  exit 0
fi
OWNER_ID=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$OWNER_ID" in ''|*[!0-9]*) exit 0 ;; esac

PARK_SEQ=
claim_park || exit 0

if [ -e "$STATE/.afk" ]; then
  rm -f "$FAILURE_FILE" 2>/dev/null || true
  exit 0
fi
if ! fm_supervision_needed "$STATE" "$GRACE"; then
  rm -f "$FAILURE_FILE" 2>/dev/null || true
  exit 0
fi

# Relay supplies its own poll cadence through this generated environment.
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

ARM_OUT=$(mktemp "$STATE/.codex-park-output.XXXXXX") || ARM_OUT=
ARM_PID=
PRESERVE_ARM_ON_EXIT=0
PARK_STARTED_AT=$(date +%s)
RENEW=0
# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  if [ -n "$ARM_PID" ] && [ "$PRESERVE_ARM_ON_EXIT" -ne 1 ]; then
    kill "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "$ARM_OUT" ] || rm -f "$ARM_OUT" 2>/dev/null || true
}
trap 'cleanup' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "$ARM_OUT" ]; then
  "$SCRIPT_DIR/fm-watch-arm.sh" > "$ARM_OUT" 2>&1 &
else
  "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
fi
ARM_PID=$!

while kill -0 "$ARM_PID" 2>/dev/null; do
  if ! park_still_ours; then
    # A newer eligible Stop attaches its own arm wrapper to this watcher's
    # singleton. Keep our wrapper alive so its TERM cleanup cannot tear that
    # shared watcher down underneath the successor. A no-work, away, or
    # replacement-session Stop still retires this arm normally.
    if current_session_still_ours && [ ! -e "$STATE/.afk" ] \
      && fm_supervision_needed "$STATE" "$GRACE"; then
      PRESERVE_ARM_ON_EXIT=1
    fi
    exit 0
  fi
  if ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    exit 0
  fi
  if [ $(( $(date +%s) - PARK_STARTED_AT )) -ge "$RENEW_SECONDS" ]; then
    RENEW=1
    break
  fi
  sleep "$POLL"
done
if [ "$RENEW" -eq 1 ]; then
  kill "$ARM_PID" 2>/dev/null || true
fi
wait "$ARM_PID" 2>/dev/null || true
ARM_PID=

[ -e "$STATE/.afk" ] && { rm -f "$FAILURE_FILE" 2>/dev/null || true; exit 0; }
park_still_ours || exit 0
current_session_still_ours || exit 0

if [ -n "$ARM_OUT" ] && grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$ARM_OUT" 2>/dev/null; then
  WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" 2>/dev/null | head -8)
  failure_episode_reset || true
  emit_continuation watcher "firstmate watcher wake - one supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle parks automatically."
fi

# A terminal one-shot source may retire its last supervision registration as it
# prints the actionable wake above. Inspect that output before treating the
# resulting no-work state as a clean close, or the durable event has no callback.
if ! fm_supervision_needed "$STATE" "$GRACE"; then
  failure_episode_reset || true
  exit 0
fi

if [ "$RENEW" -eq 1 ]; then
  failure_episode_reset || true
  emit_continuation turn-end-guard "FIRSTMATE CODEX WATCHER PARK RENEWAL - the synchronous Stop hook reached its bounded renewal interval before the native hook timeout.

No watcher event is implied. Let this continuation end normally after checking for queued wakes; the next Stop automatically establishes a fresh watcher park. Do not launch bin/fm-watch-arm.sh from the model."
fi

# A non-actionable arm close is a continuity failure even if a leftover beacon
# is fresh. Its bounded episode is owned here because stop_hook_active also
# follows genuine wake and renewal continuations.
handle_park_failure
