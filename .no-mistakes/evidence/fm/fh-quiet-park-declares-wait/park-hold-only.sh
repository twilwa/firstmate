#!/usr/bin/env bash
# Live lab driver: fm-send --resolve-key <k> --park where <k> answers only a
# captain-held backlog task (no open status key). Arm ok: the paused wait is
# appended. Arm ro: the status file is read-only, and the error must name the
# declared parked wait rather than an empty decision-key list.
# Usage: park-hold-only.sh <worktree-root> <transcript>
set -u
ROOT=$1 OUT=$2
say() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$1" | tee -a "$OUT"; }
for arm in ok ro; do
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
  export TMUX_TMPDIR="$TD"; unset TMUX
  SOCK="$TD/tmux-$(id -u)/default"; mkdir -p "$(dirname "$SOCK")"; chmod 700 "$(dirname "$SOCK")"
  STATE="$LAB/state"
  tmux -S "$SOCK" new-session -d -s lab -n w1 -x 200 -y 50 "cat" || exit 1
  mkdir -p "$LAB/data/wt"
  printf 'window=lab:w1\nbackend=tmux\nharness=claude\nkind=ship\nworktree=%s\n' "$LAB/data/wt" > "$STATE/t1.meta"
  printf 'working: waiting on the captain\n' > "$STATE/t1.status"
  say "[$arm] \$ fm-captain-hold.sh hold t1-decision-posture --reason 'captain must pick the posture'"
  FM_HOME="$LAB" "$ROOT/bin/fm-captain-hold.sh" hold t1-decision-posture --title 'Posture for t1' --reason 'captain must pick the posture' >>"$OUT" 2>&1
  say "[$arm] hold exit=$?"
  [ "$arm" = ro ] && chmod 0400 "$STATE/t1.status"
  say "[$arm] \$ fm-send.sh t1 --resolve-key posture --park 'Stay parked until the landing batch merges'"
  FM_HOME="$LAB" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" t1 --resolve-key posture --park 'Stay parked until the landing batch merges' >"$LAB/data/out" 2>"$LAB/data/err"; rc=$?
  chmod 0600 "$STATE/t1.status"
  grep -v -E '^●|fm-gate-refuse|WARNING: watcher' "$LAB/data/err" "$LAB/data/out" | tee -a "$OUT" >/dev/null
  say "[$arm] fm-send exit=$rc"
  say "[$arm] status:"; tee -a "$OUT" < "$STATE/t1.status" >/dev/null
  FM_HOME="$LAB" bash -c '. "$1/bin/fm-classify-lib.sh"; l=$(status_declared_wait_line "$2"); status_is_paused "$l" && echo "status_is_paused: yes ($l)" || echo "status_is_paused: NO"' _ "$ROOT" "$STATE/t1.status" | tee -a "$OUT"
  if [ "$arm" = ro ]; then
    diag=$(cat "$LAB/data/err"); manual=${diag#*Close it manually with: }; manual=${manual% - do not resend the answer.}
    bash -c "$manual"; say "[ro] printed recovery exit=$?"
    FM_HOME="$LAB" bash -c '. "$1/bin/fm-classify-lib.sh"; l=$(status_declared_wait_line "$2"); status_is_paused "$l" && echo "after recovery status_is_paused: yes ($l)" || echo "after recovery status_is_paused: NO"' _ "$ROOT" "$STATE/t1.status" | tee -a "$OUT"
  fi
  tmux -S "$SOCK" kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"
done
