#!/usr/bin/env bash
# Live lab driver for fm-send --park guards: refusals (missing --resolve-key,
# duplicate --park) leave status/inbox/pane untouched, and a failed status
# append names the declared parked wait with a working recovery command.
# Usage: park-cli-guards.sh <worktree-root> <transcript>
set -u
ROOT=$1 OUT=$2
say() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$1" | tee -a "$OUT"; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
export TMUX_TMPDIR="$TD"; unset TMUX
SOCK="$TD/tmux-$(id -u)/default"; mkdir -p "$(dirname "$SOCK")"; chmod 700 "$(dirname "$SOCK")"
cleanup() { chmod -R u+w "$LAB" 2>/dev/null; tmux -S "$SOCK" kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
STATE="$LAB/state"
tmux -S "$SOCK" new-session -d -s lab -n w1 -x 200 -y 50 "cat" || exit 1
mkdir -p "$LAB/data/wt"
printf 'window=lab:w1\nbackend=tmux\nharness=claude\nkind=ship\nworktree=%s\n' "$LAB/data/wt" > "$STATE/t1.meta"
seed() { printf 'needs-decision [key=posture]: resume or stay parked?\n' > "$STATE/t1.status"; rm -rf "$STATE/t1.inbox"; tmux -S "$SOCK" clear-history -t lab:w1; tmux -S "$SOCK" send-keys -t lab:w1 C-l; sleep 0.3; }
snap() { printf 'status=%s inbox=%s pane=%s\n' "$(cksum < "$STATE/t1.status")" "$(ls "$STATE/t1.inbox" 2>/dev/null | tr '\n' ,)" "$(tmux -S "$SOCK" capture-pane -p -t lab:w1 | tr -d '\n' | cksum)"; }
for case in missing-key duplicate-park; do
  seed; before=$(snap)
  case $case in
    missing-key) args=(t1 --park) ;;
    duplicate-park) args=(t1 --resolve-key posture --park --park) ;;
  esac
  say "\$ fm-send.sh ${args[*]} 'Stay parked until the batch lands'"
  FM_HOME="$LAB" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "${args[@]}" 'Stay parked until the batch lands' >>"$OUT" 2>&1; rc=$?
  sleep 0.5; after=$(snap)
  say "exit=$rc unchanged=$([ "$before" = "$after" ] && echo yes || echo NO) ($after)"
  say "status now: $(tr '\n' '|' < "$STATE/t1.status")"
done
# Failed append: status file read-only at close time.
seed; chmod 0400 "$STATE/t1.status"
say "\$ chmod 0400 t1.status; fm-send.sh t1 --resolve-key posture --park 'Stay parked until the batch lands'"
FM_HOME="$LAB" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" t1 --resolve-key posture --park 'Stay parked until the batch lands' >"$LAB/data/out" 2>"$LAB/data/err"; rc=$?
chmod 0600 "$STATE/t1.status"
grep -v '^●' "$LAB/data/err" | grep -v fm-gate-refuse | tee -a "$OUT" >/dev/null
say "exit=$rc inbox=$(ls "$STATE/t1.inbox" | tr '\n' ,)"
diag=$(cat "$LAB/data/err"); manual=${diag#*Close it manually with: }; manual=${manual% - do not resend the answer.}
say "running printed recovery command"
bash -c "$manual"; say "recovery exit=$?"
say "status after recovery:"; tee -a "$OUT" < "$STATE/t1.status" >/dev/null
FM_HOME="$LAB" bash -c '. "$1/bin/fm-classify-lib.sh"; l=$(status_declared_wait_line "$2"); echo "declared wait line: $l"; status_is_paused "$l" && echo "status_is_paused: yes" || echo "status_is_paused: NO"' _ "$ROOT" "$STATE/t1.status" | tee -a "$OUT"
