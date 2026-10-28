#!/usr/bin/env bash
# Live driver: real fm-procevent.sh register-task/reconcile + real fm-teardown.sh
# in a disposable lab home with a private tmux server. Usage: <bin-dir> <label>
set -u
BIN=$1; LABEL=$2
WT=/home/firstmate/.no-mistakes/worktrees/8be14fbb8fb5/01M60WN55QWJCQ5H69TC4F25WM
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
chmod 700 "$LAB" "$LAB/state"
export TMUX_TMPDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/claims
cleanup() { tmux kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; pkill -f "$LAB" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
say() { printf '\n$ %s\n' "$*"; }
run() { say "$*"; "$@" 2>&1; echo "[rc=$?]"; }
mkmeta() {  # <task>
  printf '%s\n' kind=scout backend=tmux "window=fm-lab:fm-$1" "endpoint_task_id=$1" \
    "worktree=$LAB/missing-$1" "project=$LAB/missing-project" > "$LAB/state/$1.meta"
  tmux new-window -d -t fm-lab: -n "fm-$1" "sleep 900"
}
echo "== [$LABEL] bin=$BIN lab=$LAB"
tmux new-session -d -s fm-lab -n idle "sleep 900"
mkmeta worker-a; mkmeta worker-b
# Crew-hosted Lavish-style long-poll listeners owned by each worker.
run "$BIN/fm-procevent.sh" register-task lavish gtm-board worker-a -- /bin/sleep 6017
run "$BIN/fm-procevent.sh" register-task lavish other-board worker-b -- /bin/sleep 6017
run "$BIN/fm-procevent.sh" reconcile
run "$BIN/fm-procevent.sh" list
say "live listener children: ps -eo pid,args | grep '/bin/sleep 6017$'"; ps -eo pid,args | grep '/bin/sleep 6017$' | grep -v grep
run tmux list-windows -t fm-lab -F '#W'
run "$BIN/fm-teardown.sh" worker-a --force
run ls "$LAB/state"
run "$BIN/fm-procevent.sh" list
run "$BIN/fm-procevent.sh" reconcile
run "$BIN/fm-procevent.sh" list
sleep 2; say "live listener children after teardown+reconcile: ps -eo pid,args | grep '/bin/sleep 6017$'"; ps -eo pid,args | grep '/bin/sleep 6017$' | grep -v grep
run tmux list-windows -t fm-lab -F '#W'

[ "$LABEL" = base ] && exit 0
echo; echo "== [$LABEL] adversarial: pending captured round on worker-b's board"
# Re-register worker-b listener as one that completes with feedback (a real captured round).
run "$BIN/fm-procevent.sh" retire other-board --if-owner worker-b
run "$BIN/fm-procevent.sh" register-task lavish other-board worker-b -- /bin/sh -c 'echo "{\"feedback\":\"please fix\"}"'
run "$BIN/fm-procevent.sh" reconcile
sleep 3
run "$BIN/fm-procevent.sh" list
run "$BIN/fm-teardown.sh" worker-b --force
run ls "$LAB/state"
run "$BIN/fm-procevent.sh" list

echo; echo "== [$LABEL] retry after the owner acknowledges the round"
run ls "$LAB/state/procevent-inbox"
run "$BIN/fm-procevent.sh" handled other-board 1
run "$BIN/fm-teardown.sh" worker-b --force
run ls "$LAB/state"
run "$BIN/fm-procevent.sh" list
