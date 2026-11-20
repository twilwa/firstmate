# sourced: lab helpers. ROOT must be set.
LAB="$ROOT/home"
TMUX_DIR=$(cat "$ROOT/tmux_dir" 2>/dev/null)
SOCK="$TMUX_DIR/tmux-$(id -u)/default"
lab_run() { env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" SHELL=/bin/bash TERM=xterm-256color LANG="${LANG:-en_US.UTF-8}" TMUX_TMPDIR="$TMUX_DIR" TREEHOUSE_ROOT="$ROOT/treehouse" FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 "$@"; }
lt() { env -u TMUX tmux -S "$SOCK" "$@"; }
mk_brief() {  # <id>
  local id=$1 brief="$LAB/data/$1/brief.md"
  (cd "$LAB" && lab_run FM_HOME="$LAB" "$LAB/bin/fm-brief.sh" "$id" notes --mode local-only) >/dev/null || return 1
  TASK_TEXT="Lab idle worker for a live route check. Do no implementation work." \
  SPEC_TEXT="Right after setup, append one status line 'paused: lab idle worker' and end your turn. Do not edit files, poll, or run anything else. Nothing else is in scope." \
  python3 - "$brief" <<'PY'
import os, sys
p=sys.argv[1]; t=open(p).read()
t=t.replace("{TASK}", os.environ["TASK_TEXT"],1).replace("{FIRSTMATE_SPEC}", os.environ["SPEC_TEXT"],1)
open(p,"w").write(t)
PY
}
spawn() {  # <id> [args...]
  local id=$1; shift
  (cd "$LAB" && lab_run FM_HOME="$LAB" "$LAB/bin/fm-spawn.sh" "$id" "$LAB/projects/notes" --mode local-only --yolo on "$@")
}
