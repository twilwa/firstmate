#!/usr/bin/env bash
# tests/secondmate-persist-helpers.sh - the persist-modelling world shared by
# the suites that ask a live local second mate to write down its open work
# before its agent is stopped (fm-secondmate-restart and fm-secondmate-sleep).
#
# Each case is a parent home plus a session-provider stub whose exit command
# stops the agent and whose launch brief starts a replacement; once armed, the
# modelled mate answers the persist request on the parent channel with that
# request's own correlation token, so the real pending-reply machinery resolves
# it. The caller sources tests/lib.sh first and sets TMP_ROOT.

# A session-provider stub that models the two things this pass depends on: the
# harness exit command stops the agent, a launch brief starts the replacement,
# and - when armed - the live mate ANSWERS a doorbell by doing what the persist
# request asks and reporting it on the parent channel with the correlation token
# the request carried. That answer is a real status append read by the real
# pending-reply machinery, not a stubbed verdict.
make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          if [ -e "$D/remote-relaunch-start" ] && [ ! -e "$D/remote-relaunch-end" ]; then
            : > "$D/local-relaunch-during-remote"
          fi
          printf 'zsh' > "$D/command.$target"
          ;;
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command.$target" ;;
        ': Firstmate instruction waiting: list '*)
          printf 'doorbell\n' >> "$D/rings"
          if [ -x "$D/on-doorbell" ]; then
            "$D/on-doorbell" "$payload"
          fi
          if [ -f "$D/answer-inbox" ]; then
            # Model the mate: read the newest instruction it was handed and
            # report back on the parent channel, carrying the correlation token
            # the request itself embedded.
            inbox=$(cat "$D/answer-inbox")
            corr=$(cat "$inbox"/*.msg 2>/dev/null \
              | grep -oE 'corr=[0-9a-f]{16}' | head -1)
            if [ -n "$corr" ]; then
              printf 'done [%s]: open records written down\n' "$corr" \
                >> "$(cat "$D/answer-status")"
            fi
          fi
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    target=
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then target=$a; fi
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          if [ -f "$D/command.$target" ]; then cat "$D/command.$target"; else cat "$D/command"; fi
          printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
      prev=$a
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  kill-window|new-window)
    # A fresh launch (a woken mate) clears the stopped window by name and opens
    # a new one, so the inventory follows both; window ids are not modelled.
    verb=$1
    shift
    target=
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -n) name=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$verb" = kill-window ]; then
      name=${target##*:}
      name=${name#=}
      { grep -vx -- "$name" "$D/windows" 2>/dev/null || true; } > "$D/windows.next"
      mv -f "$D/windows.next" "$D/windows"
    else
      printf '%s\n' "$name" >> "$D/windows"
      printf '%s\n' "${target%:}:$name"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ''|*[!0-9]*) ;;
  *) /bin/sleep 0.01 ;;
esac
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> -> a parent home with a stub session provider.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/rings"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_stub "$dir"
  printf '%s\n' "$dir"
}

# add_local_mate <case-dir> <id> [harness] [backend-line]
# A live LOCAL second mate: a real git worktree for its home, plus the durable
# record this home keeps for it.
add_local_mate() {
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" smhome="$dir/$id-home"
  fm_git_worktree "$dir/$id-repo" "$smhome" "sm-$id"
  mkdir -p "$smhome/state" "$smhome/data" "$smhome/bin" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# agents\n' > "$smhome/AGENTS.md"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}

# arm_answer <case-dir> <id>: make the modelled mate answer the persist request.
arm_answer() {
  local dir=$1 id=$2
  printf '%s' "$dir/home/state/$id.inbox" > "$dir/fake/answer-inbox"
  printf '%s' "$dir/home/state/$id.status" > "$dir/fake/answer-status"
}
