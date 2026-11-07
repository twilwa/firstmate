# Live driver helpers: lab homes, real fork tasks-axi, real br, isolated tmux.
ROOT={run-worktree}
SHIM=/tmp/fm-taxi-build.lZpaCz/shim
export PATH="$SHIM:~/.local/share/mise/installs/node/26.13.0/bin:$PATH"
SCRATCH_HOME=$(mktemp -d /tmp/fm-live-home.XXXXXX)
export HOME=$SCRATCH_HOME
export FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1
unset TMUX TASKS_AXI_BACKEND TASKS_AXI_BEADS_PATH TASKS_AXI_BEADS_BINARY TASKS_AXI_FILE
LABS=()
say() { printf '\n$ %s\n' "$*"; }
run() { say "$*"; "$@" 2>&1; local rc=$?; echo "[exit $rc]"; return $rc; }
# new_pair <name>: sets MAIN SUB TD
new_pair() {
  MAIN=$(mktemp -d /tmp/fm-lab.XXXXXX); "$ROOT/bin/fm-lab-home.sh" create "$MAIN" >/dev/null
  SUB=$(mktemp -d /tmp/fm-lab-sub.XXXXXX)
  LABS+=("$MAIN" "$SUB")
  mkdir -p "$MAIN/data" "$MAIN/state" "$MAIN/config" "$SUB/bin" "$SUB/data" "$SUB/state" "$SUB/config"
  printf '# Firstmate\n' > "$SUB/AGENTS.md"; printf 'design\n' > "$SUB/.fm-secondmate-home"
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-11-07)\n' "$SUB" > "$MAIN/data/secondmates.md"
  printf 'window=firstmate:fm-design\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\nworktree=%s\n' "$SUB" "$SUB" > "$MAIN/state/design.meta"
  TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$MAIN")
  TMUX_TMPDIR="$TD" tmux new-session -d -s firstmate -n fm-design -x 200 -y 50 'cat'
  echo "pair: main=$MAIN sub=$SUB tmux=$TD"
}
# selector <home> <backend> [path] [binary]
selector() {
  { printf 'backend = "%s"\n' "$2"
    if [ "$2" = beads ]; then printf '[beads]\npath = "%s"\n' "$3"; [ -z "${4:-}" ] || printf 'binary = "%s"\n' "$4"; fi
  } > "$1/config/tasks.toml"
  mkdir -p "$1/$(dirname "${3:-data/x}")"; [ "$2" != beads ] || mkdir -p "$1/$3"
  echo "--- $1/config/tasks.toml"; cat "$1/config/tasks.toml"
}
mirror() { printf '[beads]\nmirror = "%s/data/backlog.md"\n' "$1" > "$1/.tasks.toml"; }
# fmaxi <home> <args...>: firstmate's own wrapper, which resolves the home's selector
fmaxi() { local h=$1; shift; (cd "$h" && FM_HOME="$h" "$ROOT/bin/fm-tasks-axi.sh" "$@"); }
brlist() { say "br --db $1 list --all --json (ids/status/title)"; br --db "$1" list --all --json 2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); d=d.get("issues",d) if isinstance(d,dict) else d; [print(i.get("id"), i.get("status"), "|", i.get("title")) for i in d]' ; }
handoff() { run env FM_HOME="$MAIN" TMUX_TMPDIR="$TD" "$ROOT/bin/fm-backlog-handoff.sh" design "$@"; }
wakes() { echo "inbox records: $(find "$MAIN/state/design.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l)"; echo "receiver pane:"; TMUX_TMPDIR="$TD" tmux capture-pane -p -t firstmate:fm-design | grep -v '^$' | tail -3; }
cleanup() { local d; for d in "${LABS[@]}"; do [ -f "$d/state/.fm-lab-tmux-dir" ] && { TMUX_TMPDIR=$(cat "$d/state/.fm-lab-tmux-dir") tmux kill-server 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" teardown "$d" >/dev/null 2>&1; }; rm -rf "$d"; done; rm -rf "$SCRATCH_HOME"; }
trap cleanup EXIT
