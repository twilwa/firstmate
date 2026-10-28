#!/usr/bin/env bash
# Live drive: arm a real Lavish board for a task in a disposable lab home, tear
# the task down with the real bin/fm-teardown.sh, then run the real reconcile.
# Usage: live-teardown-lavish.sh <repo-root-whose-bin-to-run> <lavish-port>
set -u
ROOT=$1 PORT=$2
WT=/home/firstmate/.no-mistakes/worktrees/8be14fbb8fb5/01M60N98BW20QK5TY6ZP3ERVY2
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
  FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
chmod 700 "$LAB/state"
export FM_HOME=$LAB
export FM_PROCEVENT_CLAIM_ROOT=$LAB/claims XDG_STATE_HOME=$LAB/xdg
export LAVISH_AXI_STATE_DIR=$LAB/lavish LAVISH_AXI_PORT=$PORT LAVISH_AXI_NO_OPEN=1 LAVISH_AXI_TELEMETRY=0
export TMUX_TMPDIR; TMUX_TMPDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
cleanup() {
  lavish-axi stop --port "$PORT" >/dev/null 2>&1 || true
  pkill -f "$LAB/" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT
step() { printf '\n$ %s\n' "$*"; }
run() { step "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }
runners() { step "processes running a lavish listener for this lab"; pgrep -af "fm-procevent-lavish.sh poll $LAB" | sed "s#$LAB#\$LAB#g" || echo '(none)'; }

echo "bin under test: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || cat "$ROOT/.rev"))"
tmux new-session -d -s fleet -n fm-worker-a 'sleep 600'
tmux new-window -d -t fleet -n fm-worker-b 'sleep 600'
for t in worker-a worker-b; do
  mkdir -p "$LAB/boards/$t"
  printf '<!doctype html><title>%s GTM board</title><h1>%s board</h1>\n' "$t" "$t" > "$LAB/boards/$t/board.html"
  printf '%s\n' 'kind=scout' 'backend=tmux' "window=fleet:fm-$t" "endpoint_task_id=$t" \
    "worktree=$LAB/missing-$t" "project=$LAB/missing-project" > "$LAB/state/$t.meta"
  run lavish-axi "$LAB/boards/$t/board.html"
  run "$ROOT/bin/fm-procevent-lavish.sh" arm "$LAB/boards/$t/board.html" --for "$t"
done
run "$ROOT/bin/fm-procevent.sh" list
runners

if [ "${SCENARIO:-plain}" = wrongowner ]; then
  bid=$(for s in $(ls "$LAB/state/procevent/" | sed -n 's/\.source$//p'); do sed -n 3p "$LAB/state/procevent/$s.source" | grep -q 'owner_task=worker-b$' && echo "$s"; done)
  run "$ROOT/bin/fm-procevent.sh" retire "$bid" --if-owner worker-a
  run "$ROOT/bin/fm-procevent.sh" retire "$bid" --if-owner 'not a task!'
  run "$ROOT/bin/fm-procevent.sh" list
  runners
  exit 0
fi
if [ "${SCENARIO:-plain}" = ended ]; then
  # Captain ends worker-a's board: the listener captures a terminal round nobody acknowledged.
  run lavish-axi end "$LAB/boards/worker-a/board.html"
  for _ in $(seq 1 40); do ls "$LAB/state/procevent-inbox/"*.result >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 2
  run "$ROOT/bin/fm-procevent.sh" list
  run "$ROOT/bin/fm-teardown.sh" worker-a --force
  step "task record after refused teardown"; ls "$LAB/state/" | grep -E '\.meta$' || echo '(no meta)'
  run "$ROOT/bin/fm-procevent.sh" list
  seq=$(ls "$LAB/state/procevent-inbox/" | sed -n 's/^[^.]*\.\([0-9]*\)\.result$/\1/p' | head -1)
  id=$(ls "$LAB/state/procevent/" | sed -n 's/\.source$//p' | while read -r s; do sed -n 3p "$LAB/state/procevent/$s.source" | grep -q worker-a && echo "$s"; done)
  run "$ROOT/bin/fm-procevent.sh" handled "$id" "$seq"
fi

run "$ROOT/bin/fm-teardown.sh" worker-a --force
step "task records after teardown"; ls "$LAB/state/" | grep -E '\.meta$' || echo '(no meta)'
step "tmux windows"; tmux list-windows -t fleet -F '#W' 2>&1
run "$ROOT/bin/fm-procevent.sh" list
runners
step "simulate a restart: kill any surviving listener for torn-down worker-a"
pkill -f "poll $LAB/boards/worker-a/" && echo killed || echo '(nothing to kill)'
sleep 1
run "$ROOT/bin/fm-procevent.sh" reconcile
sleep 2
run "$ROOT/bin/fm-procevent.sh" list
runners
