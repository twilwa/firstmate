#!/usr/bin/env bash
# Drive the real bin/fm-spawn.sh against the real installed Pi in a disposable
# lab home on a private tmux socket. Token-free: the isolated HOME has no Pi
# auth, the trust dialog is never answered, and every pane is killed.
# Usage: drive-real-spawn.sh <worktree> <evidence-dir>
set -u
WT=$1 E=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/user-home"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
cleanup() { T kill-server >/dev/null 2>&1; chmod -R u+w "$LAB" 2>/dev/null; rm -rf -- "$LAB"; }
trap cleanup EXIT
touch "$LAB/state/.last-watcher-beat"
printf 'pi\n' > "$LAB/config/crew-harness"

mkproj() { # <name>
  local p="$LAB/projects/$1" o="$LAB/origins/$1.git"
  mkdir -p "$p/.pi/extensions" "$LAB/origins"
  git -C "$p" init -q -b main
  printf 'export default function () {}\n' > "$p/.pi/extensions/project-ext.ts"
  printf '# %s\n' "$1" > "$p/README.md"
  git -C "$p" add -A && git -C "$p" -c user.email=lab@lab -c user.name=lab commit -qm init
  git clone -q --bare "$p" "$o" && git -C "$p" remote add origin "$o" && git -C "$p" fetch -q origin
}
mkbrief() { # <id>
  mkdir -p "$LAB/data/$1"
  cat > "$LAB/data/$1/brief.md" <<EOF
# Task
## Captain's intent
Lab trust probe for $1; do nothing.

## Firstmate spec
Exercise the Pi launch trust behavior only.
EOF
}
mkproj regproj
mkproj unregproj
printf '%s\n' '- regproj [no-mistakes] - lab registered project (added 2026-11-03)' \
  '- unregproj-other [no-mistakes] - prefix decoy, unregproj itself is unregistered' > "$LAB/data/projects.md"
cp "$LAB/data/projects.md" "$E/lab-projects.md"

# Lab primary shell on the private socket; fm-spawn inherits its $TMUX.
# Isolation lives on the tmux SERVER: spawned windows take the server's global
# environment, not the primary pane's shell. Real HOME stays so the mise pi
# shim resolves; PI_CODING_AGENT_DIR isolates Pi settings, trust, auth, sessions.
# The primary shell keeps HOME=lab so fm-spawn roots treehouse inside the lab.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PI_CODING_AGENT_DIR="$LAB/user-home/.pi/agent" PI_OFFLINE=1 \
  tmux -L fm-lab new-session -d -s primary -x 200 -y 50 -c "$WT" \
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" HOME="$LAB/user-home" PI_OFFLINE=1 bash --noprofile --norc
T set-option -g remain-on-exit on
for v in PI_CODING_AGENT_DIR; do
  got=$(T show-environment -g "$v" 2>/dev/null); case "$got" in "$v=$LAB/"*) ;; *) echo "ABORT: server $v not isolated: $got"; exit 1 ;; esac
done
echo "server env isolated: PI_CODING_AGENT_DIR under \$LAB"

spawn() { # <id> <proj> <args...>
  local id=$1 proj=$2 i; shift 2
  mkbrief "$id"
  T send-keys -t primary "bin/fm-spawn.sh $id $LAB/projects/$proj $* > $LAB/$id.spawn.log 2>&1; echo \$? > $LAB/$id.rc" Enter
  for ((i = 0; i < 600; i++)); do [ -s "$LAB/$id.rc" ] && break; sleep 0.5; done
  printf '== fm-spawn.sh %s %s %s -> rc=%s\n' "$id" "$proj" "$*" "$(cat "$LAB/$id.rc" 2>/dev/null)"
  sed "s#$LAB#\$LAB#g" "$LAB/$id.spawn.log"
}
pane_of() { # <id>
  local line; line=$(grep -h '^window=\|^pane=\|^target=' "$LAB/state/$1.meta" 2>/dev/null | head -1)
  line=${line#*=}
  [ -n "$line" ] || line=$(T list-windows -a -F '#{session_name}:#{window_index} #{window_name}' | grep -F "$1" | head -1 | cut -d' ' -f1)
  printf '%s' "$line"
}
observe() { # <id>
  local id=$1 tgt pane i
  tgt=$(pane_of "$id")
  for ((i = 0; i < 60; i++)); do
    pane=$(T capture-pane -p -t "$tgt" -S -60 2>/dev/null)
    printf '%s' "$pane" | grep -qE 'Trust project folder|escape interrupt|No models available' && break
    sleep 0.5
  done
  sleep 2; pane=$(T capture-pane -p -t "$tgt" -S -60 2>/dev/null)
  printf '%s\n' "$pane" > "$E/pane-$id.txt"
  printf -- '-- meta %s:\n' "$id"; sed "s#$LAB#\$LAB#g" "$LAB/state/$id.meta" | grep -E '^(harness|kind|worktree|window|pane|target|project)='
  printf -- '-- Pi process argv in pane (%s):\n' "$tgt"
  local pid; pid=$(T display-message -p -t "$tgt" '#{pane_pid}')
  ps -o args= --sid "$pid" 2>/dev/null | grep -E '(^|/)pi( |$)' | grep -v -e '^sh ' -e '^bash ' | sed "s#$LAB#\$LAB#g" | cut -c1-400
  for c in $(ps -o pid=,args= --sid "$pid" | awk '$2 ~ /(^|\/)pi$/ {print $1}'); do
    printf 'Pi pid env: %s\n' "$(tr '\0' '\n' < /proc/$c/environ | grep -E '^(HOME|PI_CODING_AGENT_DIR|PI_OFFLINE)=' | sed "s#$LAB#\$LAB#g" | tr '\n' ' ')"
  done
  if printf '%s' "$pane" | grep -q 'Trust project folder'; then echo "RESULT $id: TRUST DIALOG SHOWN"; else echo "RESULT $id: no trust dialog"; fi
  printf '%s' "$pane" | grep -qE 'escape interrupt|No models available' && echo "RESULT $id: Pi composer/main UI reached"
  T kill-pane -t "$tgt" >/dev/null 2>&1 || true
}

PIDIR="$LAB/user-home/.pi/agent"
mkdir -p "$PIDIR"; printf '{}\n' > "$PIDIR/trust.json"
printf '{\n  "defaultProjectTrust": "ask",\n  "lastChangelogVersion": "%s"\n}\n' "$(pi --version)" > "$PIDIR/settings.json"
cp "$PIDIR/trust.json" "$LAB/trust-before"; cp "$PIDIR/settings.json" "$LAB/settings-before"

spawn lab-reg-scout-a1 regproj --scout --backend tmux;      observe lab-reg-scout-a1
spawn lab-reg-ship-b2 regproj --mode no-mistakes --yolo off --backend tmux; observe lab-reg-ship-b2
spawn lab-unreg-scout-c3 unregproj --scout --backend tmux;  observe lab-unreg-scout-c3

echo "== Pi stores after all launches"
cmp -s "$LAB/trust-before" "$PIDIR/trust.json" && echo "trust.json unchanged: $(cat "$PIDIR/trust.json")" || { echo "trust.json CHANGED:"; cat "$PIDIR/trust.json"; }
cmp -s "$LAB/settings-before" "$PIDIR/settings.json" && echo "settings.json unchanged (defaultProjectTrust=ask)" || { echo "settings.json CHANGED:"; cat "$PIDIR/settings.json"; }
