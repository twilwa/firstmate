#!/usr/bin/env bash
# Drives the real bin/fm-herdr-session-cleanup.sh executable in an isolated
# FM_HOME. Herdr itself is replaced by a PATH shim (the guarded Herdr lab could
# not be provisioned on this host), so every Herdr response is simulated.
set -u
ROOT=${1:?worktree root}
WORK=$(mktemp -d /tmp/fm-live-cleanup.XXXXXX)
TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=task
TITLE="└ $ID · p:$TOKEN"
say() { printf '%s\n' "$*"; }

setup() { # <name>
  H=$WORK/$1; mkdir -p "$H/state" "$H/config" "$H/fakebin"
  printf 'herdr\n' > "$H/config/backend"; : > "$H/config/herdr-presentation-spaces"
  printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$ID" "$TOKEN" > "$H/state/$ID.herdr-presentation"
  cp "$H/state/$ID.herdr-presentation" "$H/journal.orig"
  cat > "$H/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LIVE_HERDR_LOG"
case "${1:-} ${2:-}" in
  "session list") printf '{"sessions":[{"name":"test","running":true,"socket_path":"%s"}]}\n' "$LIVE_SOCKET" ;;
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"%s","tab_count":1,"pane_count":1}]}}\n' "$LIVE_TITLE" ;;
  "api snapshot")
    owner=$(cat "$LIVE_TASK_LOCK/pid" 2>/dev/null)
    printf 'snapshot reached; task-lock owner=%s presentation-lock owner=%s\n' "$owner" "$(cat "$LIVE_PRES_LOCK/pid" 2>/dev/null)" >> "$LIVE_HERDR_LOG"
    case "$LIVE_MODE" in
      stuck|stuck-swap) kill -STOP "$owner" ;;
    esac
    if [ "$LIVE_MODE" = stuck-swap ]; then
      # Another live process now legitimately owns the shared presentation lock.
      printf '%s\n' "$LIVE_FOREIGN_PID" > "$LIVE_PRES_LOCK/pid"
    fi
    sleep 30 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$H/fakebin/herdr"
  export LIVE_HERDR_LOG=$H/herdr.log LIVE_SOCKET=$WORK/$1.sock LIVE_TITLE=$TITLE
  export LIVE_TASK_LOCK=$H/state/.spawn-$ID.lock
  LIVE_PRES_LOCK=$(PATH="$H/fakebin:$PATH" HERDR_SESSION=test FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_presentation_session_lock_path test' _ "$ROOT")
  export LIVE_PRES_LOCK
  : > "$LIVE_HERDR_LOG"
}

run_cleanup() { # <timeout>
  local t0=$SECONDS rc
  PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_BACKEND=herdr HERDR_SESSION=test \
    FM_HERDR_SESSION_CLEANUP_TIMEOUT=$1 "$ROOT/bin/fm-herdr-session-cleanup.sh" > "$H/out" 2>&1
  rc=$?
  say "\$ FM_HERDR_SESSION_CLEANUP_TIMEOUT=$1 bin/fm-herdr-session-cleanup.sh"
  say "exit=$rc elapsed=$((SECONDS - t0))s"
  sed 's/^/  stderr| /' "$H/out"
}

fresh_acquire() { # <lockdir> -> prints result
  if bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" && fm_lock_release "$2"' _ "$ROOT" "$1" 2>/dev/null; then
    say "  fresh process acquired+released $(basename "$1"): OK"
  else
    say "  fresh process could NOT acquire $(basename "$1"): holder pid=$(cat "$1/pid" 2>/dev/null)"
  fi
}

state_report() {
  say "  journal unchanged: $(cmp -s "$H/journal.orig" "$H/state/$ID.herdr-presentation" && echo yes || echo NO)"
  say "  task lock present: $([ -e "$LIVE_TASK_LOCK" ] && echo "YES (pid $(cat "$LIVE_TASK_LOCK/pid" 2>/dev/null))" || echo no)"
  say "  presentation lock present: $([ -e "$LIVE_PRES_LOCK" ] && echo "YES (pid $(cat "$LIVE_PRES_LOCK/pid" 2>/dev/null))" || echo no)"
  say "  leftover lock-record files: $(ls -A "$H/state" | grep -c '^\.herdr-cleanup-locks\.' )"
  sed 's/^/  herdr-shim| /' "$LIVE_HERDR_LOG"
}

say "### S1: home with no herdr journals (tmux home) returns without starting a worker"
H=$WORK/nojournal; mkdir -p "$H/state" "$H/config" "$H/fakebin"; printf 'tmux\n' > "$H/config/backend"
printf '#!/bin/sh\necho "$*" >> %s/herdr.log\n' "$H" > "$H/fakebin/herdr"; chmod +x "$H/fakebin/herdr"; : > "$H/herdr.log"
chmod 555 "$H/state"
t0=$(date +%s%N)
PATH="$H/fakebin:$PATH" FM_HOME="$H" bash -x "$ROOT/bin/fm-herdr-session-cleanup.sh" > "$H/out" 2> "$H/trace"; rc=$?
t1=$(date +%s%N)
chmod 755 "$H/state"
say "\$ bin/fm-herdr-session-cleanup.sh   (state dir read-only, no journals)"
say "exit=$rc elapsed=$(( (t1 - t0) / 1000000 ))ms stdout+stderr bytes(non-trace)=$(wc -c < "$H/out")"
say "  herdr invocations: $(wc -l < "$H/herdr.log")"
say "  fm_run_timed / mktemp / --_worker in trace: $(grep -cE 'fm_run_timed|mktemp|--_worker' "$H/trace")"
say "  last traced wrapper lines:"; grep -E '^\++ (fm_herdr_cleanup_has_work|exit|return)' "$H/trace" | tail -3 | sed 's/^/    /'
say ""

say "### S2: responsive worker hung in a Herdr read is bounded; locks released"
setup term; export LIVE_MODE=term
run_cleanup 2; state_report
fresh_acquire "$LIVE_TASK_LOCK"; fresh_acquire "$LIVE_PRES_LOCK"
say ""

say "### S3: stuck worker (SIGSTOPped, ignores TERM) is hard-killed; parent reclaims its recorded locks"
setup stuck; export LIVE_MODE=stuck
run_cleanup 2; state_report
fresh_acquire "$LIVE_TASK_LOCK"; fresh_acquire "$LIVE_PRES_LOCK"
say ""

say "### S4 (adversarial): after the worker stalls, a different live process owns the presentation lock; recovery must not steal it"
setup swap; export LIVE_MODE=stuck-swap
sleep 300 & export LIVE_FOREIGN_PID=$!
say "  foreign live holder pid=$LIVE_FOREIGN_PID"
run_cleanup 2; state_report
fresh_acquire "$LIVE_TASK_LOCK"
say "  foreign holder still alive: $(kill -0 $LIVE_FOREIGN_PID 2>/dev/null && echo yes || echo no); presentation lock pid file=$(cat "$LIVE_PRES_LOCK/pid" 2>/dev/null)"
kill $LIVE_FOREIGN_PID 2>/dev/null; wait $LIVE_FOREIGN_PID 2>/dev/null
rm -rf -- "$LIVE_PRES_LOCK"
say ""

say "### S5: generous deadline: a candidate that finishes leaves no lock record and no timeout warning"
setup finish; export LIVE_MODE=term
# snapshot now answers immediately with an unreadable body -> candidate preserved as ambiguous
sed -i 's/^    sleep 30 ;;/    exit 1 ;;/' "$H/fakebin/herdr"
run_cleanup 30; state_report
rm -rf "$WORK"
