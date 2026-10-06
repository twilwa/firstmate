#!/usr/bin/env bash
# fm-secondmate-sleep.sh - put a persistent second mate to sleep, and wake it,
# on purpose.
#
# Usage: fm-secondmate-sleep.sh sleep <id>... --by <who> --reason <text>
#        fm-secondmate-sleep.sh wake <id>...
#        fm-secondmate-sleep.sh status [<id>...]
#
# Run it from the PARENT home with FM_HOME explicit, exactly like bin/fm-send.sh.
# Each <id> is a mate registered in this home's data/secondmates.md. An fm-<id>
# selector names <id> only when it is not itself a registered id and <id> is.
#
# Why this exists. Every home runs its own agent and its own supervision watcher,
# so an idle mate still spends a watcher cycle - fleet snapshot, per-task reads,
# process-event reconciliation, home-summary refresh - on the host every other
# home shares. Retirement (bin/fm-teardown.sh) removes the home, and merely
# exiting the agent is undone by the liveness sweep's relaunch. Sleep is the
# durable middle: the mate's agent, watcher, and process-event listeners stop,
# while its home - data, backlog, held captain calls and their answer bindings,
# clones, and worktrees - is left exactly as it was until an explicit wake. Nothing schedules or automates
# either direction; sleep and wake are always deliberate captain or primary
# firstmate actions.
#
# The marker. state/<id>.asleep in the PARENT home is the one durable record that
# a mate is asleep. It holds three key=value lines:
#   since=<UTC ISO-8601 time the sleep completed>
#   by=<who asked, one line>
#   reason=<why, one line>
# bin/fm-secondmate-sleep-lib.sh is its one reader and writer. Every caller that
# must leave a sleeping mate alone asks that library instead of parsing the file,
# and a marker that exists but cannot be read still reads as asleep. While it
# exists the liveness sweep and watcher tick never relaunch the mate, the
# watcher's wake-loop check leaves its queue alone, /updatefirstmate lists it
# asleep instead of restarting or nudging it, config pushes and startup
# convergence never steer it and leave any reread generation it holds for the
# wake launch, bin/fm-send.sh refuses to steer it, and bearings reports it asleep.
#
# sleep, per mate. Every step is idempotent, and a sleep that cannot complete
# writes no marker and names the step that refused:
#   registered  the id is a LOCAL route in data/secondmates.md whose home carries
#               its own seed marker; a remote route is refused for now.
#   idle        the mate's own home holds no in-flight work (no state/*.meta),
#               checked at admission and again under the liveness lock just
#               before its agent is stopped.
#   agent       a running agent is asked to write down the open work it holds only
#               in its conversation, with the same request, gate, and bound that
#               bin/fm-secondmate-restart.sh uses (bin/fm-secondmate-restart-lib.sh,
#               FM_SECONDMATE_PERSIST_WAIT and FM_SECONDMATE_PERSIST_POLL), and is
#               stopped with bin/fm-control.sh <id> exit only after its correlated
#               answer lands. An agent that is already stopped has nothing to
#               persist; one whose state cannot be read is refused. The stop and
#               every later step run under this home's per-mate liveness lock, so
#               no liveness check relaunches the mate before its marker lands; an
#               agent that was stopped at admission is probed again under that
#               lock, and one that came back up meanwhile is refused unstopped.
#   watcher     the home's own bin/fm-watch-arm.sh --stop stops its watcher.
#   listeners   each process-event source registered in the home is asked about
#               through the home's own bin/fm-captain-hold.sh binding <source-id>.
#               A decision-bound source stays registered with its binding, but
#               its runner does not keep running while the mate sleeps: a runner
#               stops once its home shows no activity for the process-event owner
#               lease, and sleep stops everything in the home that would renew
#               it. A board answer given while the mate sleeps is queued by Lavish
#               and captured once the mate wakes and that listener relaunches,
#               never while it sleeps. Every unbound source is retired through
#               the home's own bin/fm-procevent.sh retire <source-id>, owner
#               matched: an extension registration only with its exact
#               --if-owner token, and an unacknowledged task-owned round
#               refuses. A refusal names the source.
#   marker      state/<id>.asleep is written.
# A mate already asleep is a no-op that says so. Every persist request goes out
# before any stop, so one slow answer delays only its own mate.
#
# wake, per mate. The marker is removed, then the mate is relaunched through the
# same guarded path liveness recovery uses (bin/fm-secondmate-liveness-lib.sh:
# a stopped endpoint is cleared first, then bin/fm-spawn.sh <id> --secondmate,
# which converges the home's tracked files and inherited material and clears
# reread generations the new agent no longer needs), and the agent is confirmed
# live. Then the home's own bin/fm-procevent.sh reconcile runs once, so every
# listener still registered there - a decision-bound one kept through sleep -
# relaunches and collects its queued answer at once rather than at the new
# watcher's first cycle; a refused reconcile is reported on the wake line and
# never undoes the wake. The new agent's own session start arms its watcher. A
# mate with no marker is a no-op that says so. A failed relaunch is reported as
# failed; the marker stays removed, so ordinary liveness recovery owns the mate
# from there.
#
# status prints one line per registered mate, or per named id: asleep since when,
# by whom, and why, or awake.
#
# Every result is one line, "<id>: <outcome>". Nothing here forces, stashes,
# discards, or tears anything down, and nothing touches a mate's own data,
# backlog, projects, or worktrees.
#
# Exit status: 0 every named mate reached the asked state; 3 at least one was
# refused or failed and every mate is still accounted for; 1 the home itself is
# unusable; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,97{s/^# \{0,1\}//;p;}' "$0"
}

VERB=${1:-}
case "$VERB" in
  -h|--help) usage; exit 0 ;;
  sleep|wake|status) shift ;;
  *) usage >&2; exit 2 ;;
esac

BY=""
REASON_TEXT=""
RAW_IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --by|--reason)
      [ "$VERB" = sleep ] || { echo "error: $1 is only for sleep" >&2; exit 2; }
      [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
      case "$2" in
        *[[:cntrl:]]*) echo "error: $1 must be one line of plain text" >&2; exit 2 ;;
      esac
      if [ "$1" = --by ]; then BY=$2; else REASON_TEXT=$2; fi
      shift 2
      ;;
    -*) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
    *)
      case "$1" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $1" >&2; exit 2 ;; esac
      RAW_IDS+=("$1")
      shift
      ;;
  esac
done
if [ "$VERB" = sleep ]; then
  [ -n "$BY" ] && [ -n "$REASON_TEXT" ] \
    || { echo "error: sleep records who asked and why: pass --by <who> and --reason <text>" >&2; exit 2; }
fi
if [ "$VERB" != status ] && [ "${#RAW_IDS[@]}" -eq 0 ]; then
  echo "error: $VERB needs at least one second mate id" >&2
  exit 2
fi

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-sleep refuses to resolve second mates without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 1; }
REG="${FM_DATA_OVERRIDE:-$FM_HOME/data}/secondmates.md"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

IDS=()
for raw in "${RAW_IDS[@]+"${RAW_IDS[@]}"}"; do
  id=$raw
  case "$raw" in
    fm-?*)
      secondmate_registry_line_for_id "$REG" "$raw" \
        || ! secondmate_registry_line_for_id "$REG" "${raw#fm-}" \
        || id=${raw#fm-}
      ;;
  esac
  case " ${IDS[*]:-} " in *" $id "*) ;; *) IDS+=("$id") ;; esac
done

failures=0

# The line of a command's output that says why it refused: its first "error:"
# line, else its first line that carries anything, flattened to one line.
first_line() {  # <text>
  local line
  line=$(printf '%s\n' "$1" | sed -n '/^error: /{s/^error: //;p;q;}')
  [ -n "$line" ] || line=$(printf '%s\n' "$1" | sed -n '/./{p;q;}')
  printf '%s\n' "$line" | sed 's/[[:space:]]\{1,\}/ /g'
}

# Hold this home's per-mate liveness lock, waiting out a check already in progress.
take_liveness_lock() {  # <id>
  local tries=0
  until fm_secondmate_liveness_lock "$1"; do
    tries=$((tries + 1))
    [ "$tries" -lt 120 ] || return 1
    sleep 1
  done
}

# Resolve one id to its registered local home, or print why not and fail.
# Publishes MATE_HOME.
MATE_HOME=""
resolve_local_mate() {  # <id>
  local id=$1 marker
  MATE_HOME=""
  if ! secondmate_registry_line_for_id "$REG" "$id"; then
    echo "$id: refused at registered: not a second mate registered in $REG"
    return 1
  fi
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    echo "$id: refused at registered: it runs on $SECONDMATE_REGISTRY_HOST, and a remote route cannot sleep yet"
    return 1
  fi
  marker="$SECONDMATE_REGISTRY_HOME/.fm-secondmate-home"
  if [ ! -f "$marker" ] || [ -L "$marker" ] || [ "$(cat "$marker" 2>/dev/null || true)" != "$id" ]; then
    echo "$id: refused at registered: $SECONDMATE_REGISTRY_HOME is not that mate's seeded home"
    return 1
  fi
  MATE_HOME=$SECONDMATE_REGISTRY_HOME
}

# Run one of the mate home's OWN scripts against that home, never this one.
run_in_mate_home() {  # <home> <script> <args...>
  local home=$1 script=$2
  shift 2
  if [ ! -x "$home/bin/$script" ]; then
    printf 'its home has no bin/%s\n' "$script"
    return 1
  fi
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$home" "$home/bin/$script" "$@" < /dev/null 2>&1
}

# The task ids of the in-flight work the mate's own home holds, space-led.
inflight_work() {  # <home>
  local meta pending=""
  for meta in "$1"/state/*.meta; do
    [ -e "$meta" ] || continue
    meta=${meta##*/}
    pending="$pending ${meta%.meta}"
  done
  printf '%s' "$pending"
}

# Probe whether <id>'s agent is running, through the liveness library, leaving
# its verdict in FM_SM_LIVE_STATUS; a mate with no durable record here has no
# endpoint to probe and reads silent.
probe_agent() {  # <id>
  FM_SM_LIVE_STATUS=silent
  FM_SM_LIVE_REASON=""
  [ ! -f "$STATE/$1.meta" ] || fm_secondmate_liveness_probe "$STATE/$1.meta" "$1" poll
}

# Retire every process-event source in the mate's home that no held captain
# call is bound to, each through the home's own owner-matched retire. A
# decision-bound source stays armed. Prints why on the first refusal.
retire_unbound_listeners() {  # <home>
  local home=$1 path id out owner_state guard
  for path in "$(fm_procevent_registry_dir "$home/state")"/*.source; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    id=${path##*/}
    id=${id%.source}
    if out=$(run_in_mate_home "$home" fm-captain-hold.sh binding "$id"); then
      continue
    elif [ -n "$out" ]; then
      printf '%s: %s\n' "$id" "$(first_line "$out")"
      return 1
    fi
    guard=()
    if ! fm_procevent_source_lock_acquire "$id"; then
      printf '%s: cannot lock the source\n' "$id"
      return 1
    fi
    fm_procevent_extension_registration_load_locked "$home/state" "$id"
    owner_state=$?
    fm_procevent_source_lock_release "$id"
    case "$owner_state" in
      0) guard=(--if-owner "$FM_PROCEVENT_EXTENSION_REGISTRATION_TOKEN") ;;
      1) ;;
      *)
        printf '%s: cannot safely read its registration owner\n' "$id"
        return 1
        ;;
    esac
    if ! out=$(run_in_mate_home "$home" fm-procevent.sh retire "$id" "${guard[@]+"${guard[@]}"}"); then
      printf '%s: %s\n' "$id" "$(first_line "$out")"
      return 1
    fi
  done
}

# --- sleep -------------------------------------------------------------------

# Per-mate pass state, parallel indexed arrays so this stays bash-3.2 safe.
# PLAN: stop (nothing to persist) | persist-pending | done.
PLAN=()
HOME_OF=()
NEEDS_EXIT=()
CORR=()
DEADLINE=()

refuse() {  # <index> <step> <reason>
  echo "${IDS[$1]}: refused at $2: $3"
  PLAN[$1]="done"
  failures=$((failures + 1))
}

# Steps idle (again), agent (the stop half), watcher, listeners, and marker,
# under the lock.
stop_and_mark() {  # <index>
  local i=$1 id out pending
  id=${IDS[$i]}
  if ! take_liveness_lock "$id"; then
    refuse "$i" agent "another liveness check kept holding this mate"
    return
  fi
  pending=$(inflight_work "${HOME_OF[i]}")
  if [ -n "$pending" ]; then
    fm_secondmate_liveness_unlock "$id"
    refuse "$i" idle "its home has in-flight work:$pending; nothing was stopped"
    return
  fi
  if [ "${NEEDS_EXIT[i]}" = 0 ]; then
    probe_agent "$id"
    case "$FM_SM_LIVE_STATUS" in
      relaunchable|silent) ;;
      alive)
        fm_secondmate_liveness_unlock "$id"
        refuse "$i" agent "its agent came back up after it was checked and was never asked to write down its open work; nothing was stopped"
        return
        ;;
      *)
        fm_secondmate_liveness_unlock "$id"
        refuse "$i" agent "cannot tell whether its agent is running: $FM_SM_LIVE_REASON; nothing was stopped"
        return
        ;;
    esac
  fi
  if [ "${NEEDS_EXIT[i]}" = 1 ] && ! out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-control.sh" "$id" exit < /dev/null 2>&1); then
    fm_secondmate_liveness_unlock "$id"
    refuse "$i" agent "$(first_line "$out")"
    return
  fi
  if ! out=$(run_in_mate_home "${HOME_OF[i]}" fm-watch-arm.sh --stop); then
    fm_secondmate_liveness_unlock "$id"
    refuse "$i" watcher "$(first_line "$out")"
    return
  fi
  if ! out=$(retire_unbound_listeners "${HOME_OF[i]}"); then
    fm_secondmate_liveness_unlock "$id"
    refuse "$i" listeners "$out"
    return
  fi
  if ! fm_secondmate_asleep_write "$STATE" "$id" "$BY" "$REASON_TEXT"; then
    fm_secondmate_liveness_unlock "$id"
    refuse "$i" marker "could not write $STATE/$id.asleep"
    return
  fi
  fm_secondmate_liveness_unlock "$id"
  fm_secondmate_asleep "$STATE" "$id"
  echo "$id: $(fm_secondmate_asleep_line)"
  PLAN[i]="done"
}

# Admit one mate: every check before anything moves, then the persist request
# when its agent is running. Leaves PLAN at stop, persist-pending, or done.
admit_for_sleep() {  # <index> <persist-request>
  local i=$1 request=$2 id pending
  id=${IDS[$i]}
  PLAN[i]="done" HOME_OF[i]="" NEEDS_EXIT[i]=0 CORR[i]="" DEADLINE[i]=""
  if fm_secondmate_asleep "$STATE" "$id"; then
    echo "$id: already $(fm_secondmate_asleep_line)"
    return
  fi
  if ! resolve_local_mate "$id"; then
    failures=$((failures + 1))
    return
  fi
  HOME_OF[i]=$MATE_HOME
  pending=$(inflight_work "$MATE_HOME")
  if [ -n "$pending" ]; then
    refuse "$i" idle "its home has in-flight work:$pending"
    return
  fi
  PLAN[i]=stop
  probe_agent "$id"
  case "$FM_SM_LIVE_STATUS" in
    relaunchable|silent) ;;
    alive)
      NEEDS_EXIT[i]=1
      if fm_secondmate_persist_ask "$FM_HOME" "$STATE" "$id" "$request"; then
        CORR[i]=$FM_SECONDMATE_PERSIST_CORR
        DEADLINE[i]=$(($(date +%s) + FM_SECONDMATE_PERSIST_WAIT_SECS))
        PLAN[i]=persist-pending
      else
        refuse "$i" agent "$FM_SECONDMATE_PERSIST_REASON; nothing was stopped"
      fi
      ;;
    *) refuse "$i" agent "cannot tell whether its agent is running: $FM_SM_LIVE_REASON" ;;
  esac
}

run_sleep() {
  local i request now next_wait remaining pending
  fm_secondmate_persist_bounds || exit 2
  request=$(fm_secondmate_persist_request 'I am about to put you to sleep: your agent and your watcher will stop and stay stopped until the captain or firstmate wakes you on purpose, which drops your conversation but keeps your home and every durable record. Every process-event listener with no held captain call bound to it is retired; a decision-bound listener stays registered with its binding but does not run while you sleep, so a board answer given meanwhile is queued by Lavish and captured once you are woken and that listener relaunches.')

  # Every mate is admitted first, so the fleet persists together.
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    admit_for_sleep "$i" "$request"
    i=$((i + 1))
  done

  # Stop each mate as soon as its own answer lands; the bound ends only the wait.
  while :; do
    pending=0
    now=$(date +%s)
    next_wait=$FM_SECONDMATE_PERSIST_POLL_SECS
    i=0
    while [ "$i" -lt "${#IDS[@]}" ]; do
      case "${PLAN[i]}" in
        stop) stop_and_mark "$i" ;;
        persist-pending)
          if fm_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
            stop_and_mark "$i"
          elif [ "$now" -ge "${DEADLINE[i]}" ]; then
            refuse "$i" agent "it did not confirm within ${FM_SECONDMATE_PERSIST_WAIT_SECS}s that its open work is written down; nothing was stopped"
          else
            pending=$((pending + 1))
            remaining=$((DEADLINE[i] - now))
            [ "$remaining" -ge "$next_wait" ] || next_wait=$remaining
          fi
          ;;
      esac
      i=$((i + 1))
    done
    [ "$pending" -gt 0 ] || break
    sleep "$next_wait"
  done
}

# --- wake --------------------------------------------------------------------

# Report a woken mate awake once its own home has relaunched every listener
# still registered there, through that home's own process-event reconcile, so a
# decision-bound source kept through sleep collects its queued board answer now
# rather than at its new watcher's first cycle. A refused reconcile is reported
# on the same line and never undoes the wake.
report_awake() {  # <id> <home> <how>
  local out
  if out=$(run_in_mate_home "$2" fm-procevent.sh reconcile); then
    echo "$1: awake; $3"
  else
    echo "$1: awake; $3; its listeners were not all relaunched yet: $(first_line "$out")"
  fi
}

# Bring a just-woken mate up through the liveness recovery path and confirm it
# live. The caller holds its liveness lock and has already removed its marker.
relaunch_woken_mate() {  # <id> <home>
  local id=$1 home=$2 meta="$STATE/$1.meta" out="" rc=0
  probe_agent "$id"
  case "$FM_SM_LIVE_STATUS" in
    alive)
      report_awake "$id" "$home" "its agent was already running"
      return 0
      ;;
    relaunchable)
      fm_secondmate_liveness_relaunch "$meta" "$id" || rc=$?
      out=$FM_SM_LIVE_OUT
      ;;
    silent)
      if [ -f "$meta" ]; then
        out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1) || rc=$?
      else
        out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" \
          "$home" --secondmate 2>&1) || rc=$?
      fi
      ;;
    *)
      echo "$id: wake failed: $FM_SM_LIVE_REASON; the marker is removed, so liveness recovery owns it now"
      return 1
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    echo "$id: wake failed: the relaunch failed: $(first_line "${FM_SM_LIVE_REASON:-$out}"); the marker is removed, so liveness recovery owns it now"
    return 1
  fi
  probe_agent "$id"
  if [ "$FM_SM_LIVE_STATUS" != alive ]; then
    echo "$id: wake failed: relaunched, but its agent is not confirmed live (state: $FM_SM_LIVE_STATE); liveness recovery owns it now"
    return 1
  fi
  report_awake "$id" "$home" relaunched
}

wake_one() {  # <id>
  local id=$1 home rc=0
  if ! fm_secondmate_asleep "$STATE" "$id"; then
    echo "$id: not asleep; nothing to wake"
    return 0
  fi
  if ! secondmate_registry_line_for_id "$REG" "$id"; then
    echo "$id: wake failed: not a second mate registered in $REG; the marker was left in place"
    return 1
  fi
  home=$SECONDMATE_REGISTRY_HOME
  if ! take_liveness_lock "$id"; then
    echo "$id: wake failed: another liveness check kept holding this mate; it is still asleep"
    return 1
  fi
  if fm_secondmate_asleep_clear "$STATE" "$id"; then
    relaunch_woken_mate "$id" "$home" || rc=$?
  else
    echo "$id: wake failed: could not remove $STATE/$id.asleep; it is still asleep"
    rc=1
  fi
  fm_secondmate_liveness_unlock "$id"
  return "$rc"
}

# --- status ------------------------------------------------------------------

status_one() {  # <id>
  local id=$1
  if fm_secondmate_asleep "$STATE" "$id"; then
    echo "$id: $(fm_secondmate_asleep_line)"
  elif secondmate_registry_line_for_id "$REG" "$id"; then
    echo "$id: awake"
  else
    echo "$id: not a second mate registered in $REG"
    return 1
  fi
}

case "$VERB" in
  sleep) run_sleep ;;
  wake)
    for id in "${IDS[@]}"; do
      wake_one "$id" || failures=$((failures + 1))
    done
    ;;
  status)
    if [ "${#IDS[@]}" -eq 0 ] && [ -f "$REG" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "- "*) ;; *) continue ;; esac
        secondmate_registry_parse_line "$line" || continue
        IDS+=("$SECONDMATE_REGISTRY_ID")
      done < "$REG"
    fi
    for id in "${IDS[@]+"${IDS[@]}"}"; do
      status_one "$id" || failures=$((failures + 1))
    done
    ;;
esac

[ "$failures" -eq 0 ] || exit 3
exit 0
