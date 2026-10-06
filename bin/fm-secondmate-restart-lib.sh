# shellcheck shell=bash disable=SC2034
# fm-secondmate-restart-lib.sh - the shared contract for restarting a second
# mate onto the current instruction surface and launch-time wiring. Source only.
#
# Two consumers, one owner:
#   - bin/fm-update.sh decides WHICH live mates belong in the restart set, so it
#     needs the capability test before it prints its action lines.
#   - bin/fm-secondmate-restart.sh performs the pass, so it needs the same test
#     again on its own argv rather than trusting a caller's list.
# The persist gate below - the request, its bounds, and its delivery under a
# parent-owned reply expectation - is also what bin/fm-secondmate-sleep.sh asks
# before it stops a mate's agent, so both stops spend a conversation only after
# the same correlated answer.
#
# The capability test is the pre-stop half of the control plane's own refusals
# (bin/fm-control-lib.sh owns those tables): a mate whose recorded backend has
# no recovery-grade agent-state classifier, or whose harness has no verified
# control mechanics, can never have "the old agent stopped and the replacement
# came up" proven for it. Asking here keeps that verdict on the side of the
# transaction where nothing has been touched yet, so an incapable mate is routed
# to the ordinary re-read nudge instead of being stopped for a launch that must
# be refused.
#
# Placement is resolved from the same remote_host= signal bin/fm-send.sh routes
# on, and it changes only the transport: the restart itself is bin/fm-control.sh
# <id> relaunch either way, run here for a local mate and run on the host over
# bin/fm-on.sh for a remote one.

_FM_SECONDMATE_RESTART_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-pending-reply-lib.sh"

# The persist request the primary sends before it stops a mate's agent. It is
# the open-record half of /stow and nothing more: a stop needs the state of work
# written down, not a memory curation pass, and bundling one would make every
# instruction update cost far more than the reload it is paying for.
# The mate answers through its parent channel, which is what resolves the
# parent-owned reply expectation fm-send arms for a marked request; that
# correlated answer, never the wall clock, is what releases the stop.
# fm_secondmate_persist_request opens the request with one sentence saying why
# the agent is about to stop; FM_SECONDMATE_PERSIST_REQUEST is the restart's.
FM_SECONDMATE_PERSIST_BODY='Before that, persist the open work you are holding only in this conversation, following the /stow skill'"'"'s "Open-record persistence" section and nothing else from that skill: file a task for each open record that exists only in this conversation, including any captain call you had formed but never registered, and correct any task whose status no longer reflects what you now know. Do NOT run the memory, learnings, or captain-preference sweeps. Then reply on your parent channel saying it is done, or saying what you deliberately left alone and why.'
fm_secondmate_persist_request() {  # <why-sentence>
  printf '%s %s' "$1" "$FM_SECONDMATE_PERSIST_BODY"
}
FM_SECONDMATE_PERSIST_REQUEST=$(fm_secondmate_persist_request 'Firstmate was updated and I am about to restart your agent so it comes up on the current instructions and launch-time settings, which drops your conversation but keeps every durable record.')

# The bound on waiting for one mate's persist answer, from the environment:
#   FM_SECONDMATE_PERSIST_WAIT  seconds to wait for one mate's answer (900)
#   FM_SECONDMATE_PERSIST_POLL  seconds between checks of that answer (5)
# Publishes FM_SECONDMATE_PERSIST_WAIT_SECS and FM_SECONDMATE_PERSIST_POLL_SECS,
# or prints the refusal and returns 1 for an unusable value. The bound ends the
# wait; it never authorizes a stop without the answer.
fm_secondmate_persist_bounds() {
  FM_SECONDMATE_PERSIST_WAIT_SECS=${FM_SECONDMATE_PERSIST_WAIT:-900}
  FM_SECONDMATE_PERSIST_POLL_SECS=${FM_SECONDMATE_PERSIST_POLL:-5}
  case "$FM_SECONDMATE_PERSIST_WAIT_SECS" in ''|*[!0-9]*)
    echo "error: FM_SECONDMATE_PERSIST_WAIT must be a non-negative integer: $FM_SECONDMATE_PERSIST_WAIT_SECS" >&2
    return 1 ;;
  esac
  case "$FM_SECONDMATE_PERSIST_POLL_SECS" in ''|*[!0-9]*|0)
    echo "error: FM_SECONDMATE_PERSIST_POLL must be a positive integer: $FM_SECONDMATE_PERSIST_POLL_SECS" >&2
    return 1 ;;
  esac
}

# Ask one mate to persist: arm the parent-owned reply expectation, then deliver
# <request> under it through fm-send. Publishes FM_SECONDMATE_PERSIST_CORR, the
# id the caller resolves with fm_pending_reply_try_resolve before it stops
# anything. On failure an undelivered expectation is discarded, and
# FM_SECONDMATE_PERSIST_REASON says which half failed.
FM_SECONDMATE_PERSIST_CORR=""
FM_SECONDMATE_PERSIST_REASON=""
fm_secondmate_persist_ask() {  # <parent-home> <state-dir> <id> <request>
  local home=$1 state=$2 id=$3 request=$4 corr send_out
  FM_SECONDMATE_PERSIST_CORR=""
  FM_SECONDMATE_PERSIST_REASON=""
  if ! corr=$(fm_pending_reply_create "$home" "$state" "$id" "$request"); then
    FM_SECONDMATE_PERSIST_REASON="its answer about the open work cannot be tracked"
    return 1
  fi
  if ! send_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-send.sh" "$id" "$request" 2>&1); then
    fm_pending_reply_discard_undelivered "$state" "$corr" >/dev/null 2>&1 || true
    FM_SECONDMATE_PERSIST_REASON="the request to write down its open work could not be delivered: $(printf '%s\n' "$send_out" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}')"
    return 1
  fi
  FM_SECONDMATE_PERSIST_CORR=$corr
}

# Resolve one mate's restart capability from its durable record alone.
# Publishes, on success:
#   FM_SECONDMATE_RESTART_PLACEMENT  local|remote
#   FM_SECONDMATE_RESTART_BACKEND    the backend whose classifier must prove the stop
#   FM_SECONDMATE_RESTART_HARNESS    the verified control adapter it runs on
#   FM_SECONDMATE_RESTART_HOST       the configured host (remote placement only)
# and on failure sets FM_SECONDMATE_RESTART_REASON to one operator-readable line.
FM_SECONDMATE_RESTART_PLACEMENT=""
FM_SECONDMATE_RESTART_BACKEND=""
FM_SECONDMATE_RESTART_HARNESS=""
FM_SECONDMATE_RESTART_HOST=""
FM_SECONDMATE_RESTART_REASON=""
fm_secondmate_restart_capable() {  # <meta-file>
  local meta=$1 kind window remote_host backend harness family
  FM_SECONDMATE_RESTART_PLACEMENT=""
  FM_SECONDMATE_RESTART_BACKEND=""
  FM_SECONDMATE_RESTART_HARNESS=""
  FM_SECONDMATE_RESTART_HOST=""
  FM_SECONDMATE_RESTART_REASON=""

  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    FM_SECONDMATE_RESTART_REASON="no durable record for this second mate in this home"
    return 1
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" != secondmate ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record is not a second mate's"
    return 1
  fi
  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record names no endpoint, so there is no agent to replace"
    return 1
  fi
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    FM_SECONDMATE_RESTART_PLACEMENT=remote
    FM_SECONDMATE_RESTART_HOST=$remote_host
    # A remote mate's endpoint record lives on its host; the parent's own record
    # names the backend that launch established there, and the remote route
    # accepts nothing but herdr.
    backend=$(fm_meta_get "$meta" remote_backend)
    [ -n "$backend" ] || backend=herdr
  else
    FM_SECONDMATE_RESTART_PLACEMENT=local
    backend=$(fm_backend_of_meta "$meta")
  fi
  FM_SECONDMATE_RESTART_BACKEND=$backend
  if ! fm_control_backend_state_verified "$backend"; then
    FM_SECONDMATE_RESTART_REASON="its runtime cannot prove an agent stopped and came back (backend $backend)"
    return 1
  fi
  if ! family=$(fm_control_harness_family "$harness") \
    || ! fm_control_harness_supported "$family" \
    || ! fm_control_harness_supports_kind "$family" secondmate; then
    FM_SECONDMATE_RESTART_REASON="its worker runtime '${harness:-none}' has no verified restart mechanics for a second mate"
    return 1
  fi
  FM_SECONDMATE_RESTART_HARNESS=$family
  return 0
}
