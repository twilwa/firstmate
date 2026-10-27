#!/usr/bin/env bash
# Drive one real bin/fm-spawn.sh --harness kimi --backend herdr in a named
# fm-lab-* Herdr session. Usage: drive-herdr.sh <ok|refused> <root> <evdir>
set -u
SCEN=$1 ROOT=$2 EV=$3
. "$ROOT/tests/lib.sh"; . "$ROOT/tests/fixtures.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION TMUX
SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name "kimi$SCEN")
LAB=$(mktemp -d /tmp/fm-kimi-herdr.XXXXXX); LAB=$(cd "$LAB" && pwd -P)
H="$LAB/fm"; PROJ="$LAB/project"; WT="$LAB/wt"; ID="kimih${SCEN}"
LOG="$EV/spawn-herdr-$SCEN.transcript.txt"; : > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
PREPARED=0
cleanup() {
  [ "$PREPARED" = 1 ] && { "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" >>"$LAB/../fm-kimi-herdr-teardown-$SCEN.log" 2>&1; echo "teardown rc=$? session=$SESSION" >> "$LAB/../fm-kimi-herdr-teardown-$SCEN.log"; }
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf -- "$LAB"
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || exit 1
fm_test_spawn_home "$H" kimi
printf 'herdr\n' > "$H/config/backend"
printf 'manual\n' > "$H/config/backlog-backend"
fm_git_init_commit "$PROJ"
git -C "$PROJ" worktree add -q -b kimi-live "$WT"
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: use your shell tool to write the text 80235 into answer.txt in the current directory. Do no other work, do not commit, and do not delegate."
printf '\nDelivery contract: mode=local-only\nShip branch: fm/%s\n' "$ID" >> "$H/data/$ID/brief.md"
mkdir -p "$LAB/bin"
printf '#!/bin/sh\ncase " $* " in *" get "*) cd "%s" && exec /bin/bash --noprofile --norc ;; esac\nexit 0\n' "$WT" > "$LAB/bin/treehouse"
printf '#!/bin/sh\nexec /bin/bash --noprofile --norc "$@"\n' > "$LAB/bin/labshell"
chmod +x "$LAB/bin/treehouse" "$LAB/bin/labshell"
export PATH="$LAB/bin:$PATH" FM_HOME="$H" SHELL="$LAB/bin/labshell" HERDR_SESSION="$SESSION"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
"$ROOT/bin/fm-herdr-lab.sh" prepare "$SESSION" || { say "prepare failed"; exit 1; }
PREPARED=1
"$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" >/dev/null || { say "provision failed"; exit 1; }
say "# scenario=herdr-$SCEN kimi=$("$HOME/.kimi-code/bin/kimi" --version) herdr=$(herdr --version | head -1) session=$SESSION lab=$LAB"
[ "$SCEN" = refused ] && export FM_KIMI_DELIVERY_POLLS=0
say "\$ HERDR_SESSION=$SESSION FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh $ID \$PROJ --mode local-only --yolo off --harness kimi --backend herdr  (FM_KIMI_DELIVERY_POLLS=${FM_KIMI_DELIVERY_POLLS:-default})"
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --mode local-only --yolo off --harness kimi --backend herdr > "$LAB/spawn.out" 2> "$LAB/spawn.err"; rc=$?
say "exit=$rc"; say "--- stdout"; tee -a "$LOG" < "$LAB/spawn.out"; say "--- stderr"; tee -a "$LOG" < "$LAB/spawn.err"
say "--- state after spawn"
say "meta present: $([ -f "$H/state/$ID.meta" ] && echo yes || echo no)"
[ -f "$H/state/$ID.meta" ] && grep -E '^(harness|window|kind|worktree|backend)=' "$H/state/$ID.meta" | tee -a "$LOG"
say "status file:"; tee -a "$LOG" < "$H/state/$ID.status" 2>/dev/null
say "lab panes: $("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane list 2>/dev/null | jq -c '[.result.panes[]? | {pane_id, agent: (.agent // null)}]' 2>/dev/null)"
say "slot status: $(git -C "$WT" status --porcelain | tr '\n' ';')"
if [ "$SCEN" = ok ] && [ "$rc" = 0 ]; then
  W=$(awk -F= '$1=="window"{print substr($0,index($0,"=")+1)}' "$H/state/$ID.meta")
  for _ in $(seq 1 240); do [ -s "$WT/answer.txt" ] && break; sleep 0.5; done
  say "answer.txt: $(cat "$WT/answer.txt" 2>/dev/null || echo MISSING)"
  . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
  say "composer state now (cursorless herdr read): $(fm_backend_composer_state herdr "$W" 2>/dev/null)"
  say "--- worker pane ($W)"; fm_backend_capture herdr "$W" 80 2>/dev/null | tee -a "$LOG" > "$EV/spawn-herdr-ok-worker-pane.txt"
fi
