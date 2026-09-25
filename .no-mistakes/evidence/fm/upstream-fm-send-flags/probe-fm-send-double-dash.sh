#!/usr/bin/env bash
set -u
L=$1; SEND=$2; LABEL=$3
export TMUX_TMPDIR=$L/tmux; unset TMUX
export FM_GATE_REFUSE_BYPASS=1 FM_HOME=$L/probe-$LABEL FM_ROOT_OVERRIDE=$L/probe-$LABEL FM_SEND_SETTLE=0
rm -rf "$FM_HOME"; mkdir -p "$FM_HOME/state"
tmux kill-server 2>/dev/null
tmux new-session -d -s fmlab -n fm-lane-live -x 200 -y 40 'cat -A'
printf 'window=fmlab:fm-lane-live\nkind=ship\n' > $FM_HOME/state/lane-live.meta
for args in "lane-live|--force is needed on that push" "lane-live|--|literal text" "lane-live|use -- to end options"; do
  IFS='|' read -r -a a <<<"$args"
  printf '=== [%s] $ fm-send.sh' "$LABEL"; printf ' %q' "${a[@]}"; echo
  "$SEND" "${a[@]}" >/dev/null 2>$L/err; echo "exit=$?"; grep -v '^●\|^WARNING\|^\s*$' $L/err | sed 's/^/stderr| /'
done
echo "records:"; find $FM_HOME/state -name '*.msg' | sort | while read f; do printf '  %s: ' "${f##*/}"; tail -n1 "$f"; echo; done
tmux kill-server
