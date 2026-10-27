#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh --harness kimi --backend herdr against a
# guarded fm-lab-* Herdr session, a marked lab FM_HOME, and the installed Kimi.
# Usage: driver.sh <root> <scenario-name> <evidence-file> [extra env assignments...]
set -u
ROOT=$1; NAME=$2; EVID=$3; shift 3
EXTRA_ENV=("$@")
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
ORIGINAL_PATH=$PATH
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
# A fully private Herdr world: its own config dir, so its "default" session is
# a disposable server started here only as the lab helper's tripwire subject.
HX=$(mktemp -d /tmp/fmhx.XXXXXX)
export XDG_CONFIG_HOME=$HX
export FM_HERDR_LAB_STATE_DIR=$HX/lab-state
herdr server >/dev/null 2>&1 &
PRIVATE_DEFAULT_PID=$!
for _ in $(seq 1 100); do
  [ "$(herdr session list --json 2>/dev/null | jq -r '.sessions[]|select(.default)|.running')" = true ] && break
  sleep 0.2
done
log() { printf '%s\n' "$*" | tee -a "$EVID"; }
: > "$EVID"
SESSION=$("$LAB_HELPER" name "kimi-$NAME") || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-kimi-spawn-work.XXXXXX")
FAKEBIN=$WORK/fakebin; mkdir -p "$FAKEBIN"
TH_BEFORE=$(ls -1 "$HOME/.treehouse-fm" 2>/dev/null | sort)
cleanup() {
  for wt in "$WORK"/project/.trees/* "$WORK"/project/*/; do :; done
  ( cd "$WORK/project" 2>/dev/null && for d in $(treehouse status 2>/dev/null | awk '{print $NF}' | grep '^/' ); do treehouse return --force "$d" >/dev/null 2>&1; done ) || true
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 && log "# lab session $SESSION torn down" || log "# WARNING teardown of $SESSION failed"
  # fm-spawn allocates under $HOME/.treehouse-fm/<hash>; remove only the new
  # pool dirs whose slots point back into this run's disposable project.
  for d in $(comm -13 <(printf '%s\n' "$TH_BEFORE") <(ls -1 "$HOME/.treehouse-fm" 2>/dev/null | sort)); do
    if grep -rqsF "$WORK/project/.git" "$HOME/.treehouse-fm/$d"/.treehouse/*/*/*/.git 2>/dev/null \
       || [ -z "$(ls -A "$HOME/.treehouse-fm/$d/.treehouse" 2>/dev/null | grep -v gitignore)" ]; then
      rm -rf "${HOME:?}/.treehouse-fm/$d"; log "# removed disposable treehouse pool $d"
    else
      log "# WARNING left unknown new pool dir $d"
    fi
  done
  kill "$PRIVATE_DEFAULT_PID" 2>/dev/null; wait "$PRIVATE_DEFAULT_PID" 2>/dev/null
  rm -rf "$LAB" "$WORK" "$HX"
}
trap cleanup EXIT
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ]; then
  args=("\${args[@]:0:\$((n-2))}")
fi
for a in "\${args[@]}"; do case "\$a" in --session|--session=*) echo "wrapper: foreign session flag" >&2; exit 97;; esac; done
if [ "\${args[0]:-}" = --version ]; then exec env PATH="$ORIGINAL_PATH" herdr --version; fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
# Fixture project with an origin and an in-project treehouse pool.
P=$WORK/project
mkdir -p "$P"; git -C "$P" init -q -b main
printf '# kimi spawn lab fixture\n' > "$P/README.md"
printf 'root = ".trees"\n' > "$P/treehouse.toml"
printf '.trees/\n' > "$P/.gitignore"
git -C "$P" add -A; git -C "$P" -c user.name=t -c user.email=t@example.invalid commit -qm init
git clone -q --bare "$P" "$WORK/origin.git"; git -C "$P" remote add origin "file://$WORK/origin.git"; git -C "$P" fetch -q origin
ID=kimi-$NAME
mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Live delivery check for the Kimi adapter.

## Firstmate spec
Reply with the single word DONE and stop. Do not edit, create, or run anything.
EOF
printf 'kimi\n' > "$LAB/config/crew-harness"
[ "${DRIVER_MAINTAINER:-0}" = 1 ] && printf 'maintainer path:%s\n' "$P" > "$LAB/config/firstmate-role"
touch "$LAB/state/.last-watcher-beat"
"$LAB_HELPER" provision "$SESSION" >/dev/null || { log "provision failed"; exit 1; }
log "# private herdr config dir=$HX (operator ~/.config/herdr untouched)"
log "# session=$SESSION lab=$LAB project=$P kimi=$($HOME/.kimi-code/bin/kimi --version) herdr=$(herdr --version|head -1)"
log "# extra env: ${EXTRA_ENV[*]:-none}"
log "\$ fm-spawn.sh $ID <project> --harness kimi --backend herdr --mode no-mistakes --yolo off"
# Sidecar: record the worker pane while the spawn runs, so a closed pane's last
# frame is still evidence of what Kimi was doing when the spawn gave up.
( while :; do
    for pid in $(env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane list 2>/dev/null | jq -r '.result.panes[]?.pane_id'); do
      f=$(env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane read "$pid" --source visible 2>/dev/null) && [ -n "$f" ] && printf '%s\n' "$f" > "$WORK/last-frame.$pid"
    done
    sleep 1
  done ) &
SIDECAR=$!
set +e
OUT=$(cd "$P" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 "${EXTRA_ENV[@]}" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$P" --harness kimi --backend herdr --mode no-mistakes --yolo off 2>&1)
RC=$?
kill "$SIDECAR" 2>/dev/null; wait "$SIDECAR" 2>/dev/null
log "$OUT"
log "# spawn exit=$RC"
log "# --- state after spawn ---"
log "meta present: $([ -e "$LAB/state/$ID.meta" ] && echo yes || echo no)"
[ -e "$LAB/state/$ID.meta" ] && log "$(grep -E '^(harness|backend|window|endpoint|worktree|branch)=' "$LAB/state/$ID.meta")"
log "status file:"; log "$(cat "$LAB/state/$ID.status" 2>/dev/null)"
log "# treehouse pool for this clone (fm-spawn's --root):"
for d in $(comm -13 <(printf '%s\n' "$TH_BEFORE") <(ls -1 "$HOME/.treehouse-fm" 2>/dev/null | sort)); do
  log "$(cd "$P" && treehouse --root "$HOME/.treehouse-fm/$d" status 2>&1 | grep -v -e 'new version' -e 'treehouse update')"
done
log "# slot-owner claims in this clone's pool:"
for d in $(comm -13 <(printf '%s\n' "$TH_BEFORE") <(ls -1 "$HOME/.treehouse-fm" 2>/dev/null | sort)); do
  for m in "$HOME/.treehouse-fm/$d"/.treehouse/*/*/.fm-slot-owner; do
    [ -e "$m" ] && log "CLAIM $m: $(tr '\n' ' ' < "$m")"
  done
  ls -d "$HOME/.treehouse-fm/$d"/.treehouse/*/*/.fm-slot-owner >/dev/null 2>&1 || log "no .fm-slot-owner claim present"
  for wt in "$HOME/.treehouse-fm/$d"/.treehouse/*/*/project; do
    [ -d "$wt" ] && log "slot $wt HEAD: $(git -C "$wt" rev-parse --abbrev-ref HEAD 2>&1)"
  done
done
log "# local branches in project: $(git -C "$P" branch --format='%(refname:short)' | tr '\n' ' ')"
log "# lab panes:"
PANES=$(env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane list 2>/dev/null)
log "$(printf '%s' "$PANES" | jq -c '.result.panes[]? | {pane_id, cwd: .foreground_cwd, agent: .agent}' 2>/dev/null)"
log "# kimi processes in the lab worktrees:"; log "$(pgrep -af "kimi-code/bin/kimi" | grep -F "$WORK" || echo none; for pid in $(pgrep -f 'kimi-code/bin/kimi'); do c=$(readlink /proc/$pid/cwd 2>/dev/null); case "$c" in "$WORK"*) echo "pid $pid cwd $c";; esac; done)"
for f in "$WORK"/last-frame.*; do
  [ -e "$f" ] || continue
  log "# --- last recorded frame of pane ${f##*last-frame.} before the spawn returned ---"
  log "$(cat "$f")"
done
if [ "${DRIVER_WAIT_AFTER:-0}" -gt 0 ]; then
  sleep "$DRIVER_WAIT_AFTER"
  log "# kimi processes ${DRIVER_WAIT_AFTER}s after spawn returned:"
  for pid in $(pgrep -f 'kimi-code/bin/kimi'); do c=$(readlink /proc/$pid/cwd 2>/dev/null); case "$c" in "$HOME"/.treehouse-fm/*) grep -qsF "$WORK" "$c/.git" && log "LIVE kimi pid $pid cwd $c";; esac; done
fi
if [ -e "$LAB/state/$ID.meta" ] || [ "${DRIVER_WAIT_AFTER:-0}" -gt 0 ]; then
  [ -e "$LAB/state/$ID.meta" ] && sleep 20
  for pid in $(printf '%s' "$PANES" | jq -r '.result.panes[]?.pane_id'); do
    log "# --- visible pane $pid (20s after spawn) ---"
    log "$(env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane read "$pid" --source visible 2>/dev/null)"
  done
fi
exit 0
