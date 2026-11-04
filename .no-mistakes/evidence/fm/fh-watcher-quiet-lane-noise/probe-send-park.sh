#!/usr/bin/env bash
# Live probe (test-step evidence): the real bin/fm-send.sh answers an open keyed
# needs-decision with --park against a disposable lab home whose worker is a
# real tmux pane on a lab-private socket. Expected: the decision closes, a
# self-announced `paused:` line is declared in the status file, the answer is
# durably enqueued, and the doorbell reaches the pane. Adversarial: --park
# without --resolve-key is refused and changes nothing.
# Usage: probe-send-park.sh <repo-root> <transcript>
set -u
ROOT=$1
TRANSCRIPT=$2
: > "$TRANSCRIPT"
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX; do unset "$v"; done
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-park.XXXXXX")
LAB="$TMP/lab-home"; LAB_SOCKET=''
cleanup() {
  [ -z "$LAB_SOCKET" ] || tmux -S "$LAB_SOCKET" kill-server >/dev/null 2>&1 || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$TRANSCRIPT"; }
show() { sed 's/^/    | /' "$1" | tee -a "$TRANSCRIPT"; }
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { say "lab create failed"; exit 1; }
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB"); export TMUX_TMPDIR="$TD"
LAB_SOCKET="$TD/tmux-$(id -u)/default"; mkdir -p "$(dirname "$LAB_SOCKET")"; chmod 700 "$(dirname "$LAB_SOCKET")"
STATE="$LAB/state"
tmux -S "$LAB_SOCKET" new-session -d -s lab -n worker -x 120 -y 40 "cat"
say "probe: fm-send --park at $(cd "$ROOT" && git rev-parse --short HEAD); lab home $LAB; worker pane lab:worker (cat)"

for t in t1 t2; do
  printf 'window=lab:worker\nbackend=tmux\nharness=claude\nkind=ship\n' > "$STATE/$t.meta"
  printf 'working: waiting on CI push lease\nneeds-decision [key=posture]: resume or stay parked?\n' > "$STATE/$t.status"
done

say "case 1: fm-send t1 --resolve-key posture --park 'continue, parked until the CI push lease is granted'"
FM_HOME="$LAB" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" t1 --resolve-key posture --park 'continue, parked until the CI push lease is granted' > "$TMP/c1.out" 2>&1
rc=$?; say "exit=$rc; output:"; show "$TMP/c1.out"
say "t1.status after:"; show "$STATE/t1.status"
say "t1 inbox:"; ls "$STATE/t1.inbox" 2>&1 | sed 's/^/    | /' | tee -a "$TRANSCRIPT"
sleep 1; say "worker pane after doorbell:"; tmux -S "$LAB_SOCKET" capture-pane -p -t lab:worker | grep -v '^$' | sed 's/^/    | /' | tee -a "$TRANSCRIPT"
ok1=0
[ $rc -eq 0 ] && grep -Eq '^resolved \[key=posture\]' "$STATE/t1.status" \
  && grep -Eq '^paused( \[at=[0-9]+\])?: supervisor parked: continue, parked until the CI push lease is granted$' "$STATE/t1.status" \
  && grep -rqF 'parked until the CI push lease' "$STATE/t1.inbox" && ok1=1
say "case 1 verdict: $([ $ok1 = 1 ] && echo PASS || echo FAIL)"

say "case 2 (adversarial): fm-send t2 --park 'continue, parked' (no --resolve-key)"
before=$(md5sum < "$STATE/t2.status")
FM_HOME="$LAB" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" t2 --park 'continue, parked' > "$TMP/c2.out" 2>&1
rc2=$?; say "exit=$rc2; output:"; show "$TMP/c2.out"
after=$(md5sum < "$STATE/t2.status")
ok2=0
[ $rc2 -ne 0 ] && [ "$before" = "$after" ] && ! ls "$STATE/t2.inbox"/*.msg >/dev/null 2>&1 && ok2=1
say "t2.status unchanged: $([ "$before" = "$after" ] && echo yes || echo no); t2 inbox messages: $(ls "$STATE/t2.inbox"/*.msg 2>/dev/null | wc -l)"
say "case 2 verdict: $([ $ok2 = 1 ] && echo PASS || echo FAIL)"
[ $ok1 = 1 ] && [ $ok2 = 1 ]
