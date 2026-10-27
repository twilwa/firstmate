#!/usr/bin/env bash
# Drive one real bin/fm-spawn.sh --harness kimi on a disposable lab home over a
# private tmux server. Usage: drive.sh <scenario> <root> <evdir>
#   ok        default knobs: expect success + meta + brief executed
#   refused   FM_KIMI_DELIVERY_POLLS=0: expect refusal, window closed, no meta
#   changed   FM_KIMI_DELIVERY_POLLS=0 + a side-writer dirtying the slot after
#             the pointer is typed: expect refusal, record kept, window open
set -u
SCEN=$1 ROOT=$2 EV=$3 KINDARG=${4:-scout}
. "$ROOT/tests/lib.sh"; . "$ROOT/tests/fixtures.sh"
REAL_TMUX=$(command -v tmux)
LAB=$(mktemp -d /tmp/fm-kimi-spawn.XXXXXX); LAB=$(cd "$LAB" && pwd -P)
H="$LAB/fm"; PROJ="$LAB/project"; WT="$LAB/wt"; ID="kimi${SCEN}${KINDARG}"
LOG="$EV/spawn-$SCEN-$KINDARG.transcript.txt"; : > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
cleanup() {
  [ -n "${SIDE_PID:-}" ] && kill "$SIDE_PID" 2>/dev/null
  TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$H" >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf -- "$LAB"
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || exit 1
LAB_TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$H") || exit 1
export TMUX_TMPDIR="$LAB_TMUX_DIR"
fm_test_spawn_home "$H" kimi
printf 'tmux\n' > "$H/config/backend"
printf 'manual\n' > "$H/config/backlog-backend"
fm_git_init_commit "$PROJ"
git -C "$PROJ" worktree add -q -b kimi-live "$WT"
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: use your shell tool to write the text 80235 into answer.txt in the current directory. Do no other work, do not commit, and do not delegate."
mkdir -p "$LAB/bin"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_TMUX" > "$LAB/bin/tmux"
printf '#!/bin/sh\ncase " $* " in *" get "*) cd "%s" && exec /bin/bash --noprofile --norc ;; esac\nexit 0\n' "$WT" > "$LAB/bin/treehouse"
chmod +x "$LAB/bin/tmux" "$LAB/bin/treehouse"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
tmux -f /dev/null new-session -d -s firstmate -n lab -x 160 -y 50 "/bin/bash --noprofile --norc"
tmux set-option -g default-command "/bin/bash --noprofile --norc" >/dev/null
say "# scenario=$SCEN kimi=$("$HOME/.kimi-code/bin/kimi" --version) lab=$LAB"
case "$SCEN" in
  refused) export FM_KIMI_DELIVERY_POLLS=0 ;;
  changed)
    export FM_KIMI_DELIVERY_POLLS=0 FM_KIMI_SUBMIT_SETTLE=4
    # Side writer: once the pointer is visible in the Kimi pane, dirty the slot.
    ( for _ in $(seq 1 600); do
        for w in $(tmux list-windows -a -F '#{session_name}:#{window_index}' 2>/dev/null); do
          if tmux capture-pane -p -t "$w" 2>/dev/null | grep -q 'Read the brief at'; then
            echo dirty > "$WT/side-write.txt"; echo "side-writer dirtied slot at $(date +%T.%N)" >> "$LAB/side.log"; exit 0
          fi
        done; sleep 0.1; done ) & SIDE_PID=$!
    ;;
esac
if [ "$KINDARG" = ship ]; then KARGS=(--mode local-only --yolo off); printf '\nDelivery contract: mode=local-only\nShip branch: fm/%s\n' "$ID" >> "$H/data/$ID/brief.md"; else KARGS=(--scout); fi
say "\$ FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh $ID \$PROJ ${KARGS[*]} --harness kimi   (FM_KIMI_DELIVERY_POLLS=${FM_KIMI_DELIVERY_POLLS:-default})"
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" "${KARGS[@]}" --harness kimi > "$LAB/spawn.out" 2> "$LAB/spawn.err"; rc=$?
say "exit=$rc"; say "--- stdout"; cat "$LAB/spawn.out" | tee -a "$LOG"; say "--- stderr"; cat "$LAB/spawn.err" | tee -a "$LOG"
[ -f "$LAB/side.log" ] && { say "--- side writer"; cat "$LAB/side.log" | tee -a "$LOG"; }
say "--- state after spawn"
say "meta present: $([ -f "$H/state/$ID.meta" ] && echo yes || echo no)"
[ -f "$H/state/$ID.meta" ] && grep -E '^(harness|window|kind|worktree)=' "$H/state/$ID.meta" | tee -a "$LOG"
say "status file:"; cat "$H/state/$ID.status" 2>/dev/null | tee -a "$LOG"
say "tmux windows: $(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' | tr '\n' ';')"
say "slot status: $(git -C "$WT" status --porcelain | tr '\n' ';')"
if [ "$SCEN" = ok ] && [ "$rc" = 0 ]; then
  W=$(awk -F= '$1=="window"{print substr($0,index($0,"=")+1)}' "$H/state/$ID.meta")
  for _ in $(seq 1 240); do [ -s "$WT/answer.txt" ] && break; sleep 0.5; done
  say "answer.txt: $(cat "$WT/answer.txt" 2>/dev/null || echo MISSING)"
  say "--- worker pane ($W)"; tmux capture-pane -p -t "$W" -S -60 | tee -a "$LOG" > "$EV/spawn-ok-$KINDARG-worker-pane.txt"
fi
if [ "$SCEN" != ok ]; then
  for w in $(tmux list-windows -a -F '#{session_name}:#{window_index}' | grep -v '^firstmate:0$'); do
    say "--- still-open pane $w"; tmux capture-pane -p -t "$w" -S -40 | tee -a "$LOG" > "$EV/spawn-changed-$KINDARG-open-pane.txt"
  done
fi
