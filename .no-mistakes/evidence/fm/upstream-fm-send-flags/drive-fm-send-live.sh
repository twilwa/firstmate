#!/usr/bin/env bash
# Drive real fm-send.sh against a real tmux server on an isolated TMUX_TMPDIR socket.
set -u
L=$1; SEND=$2; LABEL=$3
export TMUX_TMPDIR=$L/tmux; unset TMUX
export FM_GATE_REFUSE_BYPASS=1  # sandbox-only: temp FM_HOME + isolated tmux socket
export FM_HOME=$L/home-$LABEL FM_ROOT_OVERRIDE=$L/home-$LABEL FM_SEND_SETTLE=0
rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state"
tmux kill-server 2>/dev/null
tmux new-session -d -s fmlab -n placeholder -x 200 -y 40 'sleep 3600'
printf 'window=fmlab:fm-lane-live\nkind=ship\n' > $FM_HOME/state/lane-live.meta
printf 'window=fmlab:fm-sm-live\nkind=secondmate\n' > $FM_HOME/state/sm-live.meta
run() { # <name> <args...>
  local name=$1; shift
  # fresh panes per scenario so the capture shows only what this send typed
  tmux kill-window -t fmlab:fm-lane-live 2>/dev/null; tmux kill-window -t fmlab:fm-sm-live 2>/dev/null
  tmux new-window -d -t fmlab -n fm-lane-live 'cat -A'; tmux new-window -d -t fmlab -n fm-sm-live 'cat -A'
  sleep 0.2
  local before_inbox; before_inbox=$(ls -R $FM_HOME/state/*.inbox 2>/dev/null | grep -c '\.msg$')
  echo "=== [$LABEL] $name"
  printf '$ fm-send.sh'; printf ' %q' "$@"; echo
  "$SEND" "$@" >$L/out 2>$L/err; rc=$?
  sleep 0.4
  echo "exit=$rc"
  sed 's/^/stdout| /' $L/out | head -5
  grep -v '^\s*$' $L/err | grep -v '^●' | sed 's/^/stderr| /' | head -6
  local after_inbox; after_inbox=$(ls -R $FM_HOME/state/*.inbox 2>/dev/null | grep -c '\.msg$')
  echo "inbox .msg records: before=$before_inbox after=$after_inbox"
  for w in fm-lane-live fm-sm-live; do
    local cap; cap=$(tmux capture-pane -p -J -t fmlab:$w | grep -v '^$')
    if [ -z "$cap" ]; then echo "pane $w: (nothing typed)"; else echo "pane $w (cat -A, \$ = Enter received):"; printf '%s\n' "$cap" | cut -c1-110 | sed 's/^/  | /'; fi
  done
  echo
}
run "S1 unknown flag before message" lane-live --not-a-real-flag some text
run "S2 unknown --flag=value form" lane-live --bogus=1 hello
run "S3 ordinary text steer still delivers" lane-live "hello captain"
run "S4 single-dash message still sends" lane-live "-1 means failure"
run "S5 --key Enter still delivers" lane-live --key Enter
run "S6 --key with trailing flag" lane-live --key Enter --not-a-real-flag
run "S7 --key with trailing plain word" lane-live --key Enter stray
run "S8 --key then --fire-and-forget (reverse order)" sm-live --key Enter --fire-and-forget 0123456789abcdef
run "S9 --fire-and-forget then --key (original order)" sm-live --fire-and-forget 0123456789abcdef --key Enter
run "S10 --resolve-key with --key cross-check" lane-live --resolve-key k --key Enter
echo "=== [$LABEL] inbox records on disk:"
for f in $(find $FM_HOME/state -name '*.msg' | sort); do echo "--- ${f#$FM_HOME/}"; cat "$f" | sed 's/^/  /'; done
tmux kill-server
