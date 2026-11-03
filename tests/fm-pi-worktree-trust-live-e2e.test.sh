#!/usr/bin/env bash
# Token-free Pi worker trust guard: process-local approval at a fresh task cwd.
# Uses a private tmux server, never accepts a dialog or submits a model prompt.
# The tmux server and every Pi invocation run with lab HOME and XDG_CONFIG_HOME,
# and Pi with a lab PI_CODING_AGENT_DIR; the operator's real Pi trust.json and
# settings.json must be byte-identical afterwards. A tool-manager shim needs the
# operator HOME to resolve, so the concrete Pi binary is resolved first.
# FM_PI_WORKTREE_TRUST_WAIT_SECONDS: positive decimal seconds per startup wait
# (default 60); raise it on slower or heavily loaded hosts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_WORKTREE_TRUST_LIVE tmux
WAIT_SECONDS=${FM_PI_WORKTREE_TRUST_WAIT_SECONDS:-60}
case "$WAIT_SECONDS" in
  *[!0-9]* | 0*) fail "FM_PI_WORKTREE_TRUST_WAIT_SECONDS must be a positive decimal integer" ;;
esac
REAL_TMUX=$(type -P tmux) || fail "tmux missing after live gate"
SOCKET="fm-pi-worktree-trust-$$"
LAB=
CHECKED=0
AVAILABLE=0
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "${LAB:-}" ] || rm -rf -- "$LAB"
}
trap cleanup EXIT

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-worktree-trust.XXXXXX") || fail "mktemp failed"
REAL_PI_DIR=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
mkdir -p "$LAB/real-before" || fail "could not create real Pi snapshot directory"
for f in trust.json settings.json; do
  [ ! -e "$REAL_PI_DIR/$f" ] || cp -p "$REAL_PI_DIR/$f" "$LAB/real-before/$f" \
    || fail "could not snapshot $REAL_PI_DIR/$f"
done
ISO_HOME="$LAB/home"
ISO_XDG="$LAB/xdg-config"
mkdir -p "$ISO_HOME" "$ISO_XDG" || fail "could not create isolated HOME"
# Keep exited sessions inspectable, using no operator tmux configuration.
env HOME="$ISO_HOME" XDG_CONFIG_HOME="$ISO_XDG" \
  "$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s anchor -- sleep 240 \
  || fail "could not start private tmux server"
"$REAL_TMUX" -L "$SOCKET" set-option -g remain-on-exit on || fail "could not retain test panes"

capture_until() { # <session> <regex>
  local session=$1 expect=$2 pane='' i limit
  limit=$((WAIT_SECONDS * 5))
  for ((i = 0; i < limit; i++)); do
    pane=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$session:w" -S -100 2>/dev/null) || true
    if printf '%s' "$pane" | grep -qE "$expect"; then
      printf '%s\n' "$pane" > "$RUN_DIR/$session.txt"
      return 0
    fi
    sleep 0.2
  done
  fail "$HARNESS $VERSION_OUT: $session did not show $expect within ${WAIT_SECONDS}s:
$pane"
}

isolated_pi() { # <pi args>...
  env HOME="$ISO_HOME" XDG_CONFIG_HOME="$ISO_XDG" PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 \
    "$PI_BIN" "$@"
}

launch() { # <session> <cwd> [approval]
  local session=$1 cwd=$2
  shift 2
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$session" -n w -x 120 -y 40 -c "$cwd" -- \
    env HOME="$ISO_HOME" XDG_CONFIG_HOME="$ISO_XDG" PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 \
    "$PI_BIN" --no-session --no-skills --no-prompt-templates "$@" \
    || fail "$HARNESS $VERSION_OUT: could not launch $session"
}

expect_prompt() { # <session> <cwd>
  launch "$1" "$2"
  capture_until "$1" 'Trust project folder'
  "$REAL_TMUX" -L "$SOCKET" kill-session -t "$1" || fail "could not stop $1"
}

check_harness() {
  local PI_BIN concrete VERSION_OUT RUN_DIR PI_DIR PARENT TASK SIBLING dir
  PI_BIN=$(type -P "$HARNESS") || { printf 'skip: live: %s absent\n' "$HARNESS"; return; }
  if type -P mise >/dev/null 2>&1; then
    concrete=$(mise which "$HARNESS" 2>/dev/null) && [ -x "$concrete" ] && PI_BIN=$concrete
  fi
  AVAILABLE=$((AVAILABLE + 1))
  RUN_DIR="$LAB/$HARNESS"
  PI_DIR="$RUN_DIR/pi-agent"
  PARENT="$RUN_DIR/pool"
  TASK="$PARENT/task"
  SIBLING="$PARENT/sibling"
  mkdir -p "$PI_DIR" || fail "could not create isolated Pi directory"
  VERSION_OUT=$(isolated_pi --version 2>&1) || fail "$HARNESS --version failed: $VERSION_OUT"
  printf '# live %s version: %s\n' "$HARNESS" "$VERSION_OUT"
  if ! isolated_pi --help 2>&1 | grep -Eq -- '(^|[[:space:]])--approve([^[:alnum:]_-]|$)'; then
    printf 'skip: live: %s has no --approve; spawn keeps its compatibility fallback\n' "$HARNESS"
    return
  fi

  printf '{}\n' > "$PI_DIR/trust.json"
  printf '{\n  "defaultProjectTrust": "ask",\n  "lastChangelogVersion": "%s"\n}\n' \
    "$VERSION_OUT" > "$PI_DIR/settings.json"
  cp "$PI_DIR/trust.json" "$RUN_DIR/trust-before"
  cp "$PI_DIR/settings.json" "$RUN_DIR/settings-before"
  for dir in "$PARENT" "$TASK" "$SIBLING"; do
    mkdir -p "$dir/.pi/extensions" || fail "could not create project extension directory"
    printf 'export default function () {}\n' > "$dir/.pi/extensions/worker-trust-fixture.ts"
  done

  expect_prompt baseline "$TASK"
  pass "$HARNESS: fresh task with .pi/extensions prompts without approval"

  launch approved "$TASK" --approve
  capture_until approved 'escape interrupt|No models available'
  "$REAL_TMUX" -L "$SOCKET" send-keys -t approved:w -l PI_WORKER_TRUST_COMPOSER \
    || fail "$HARNESS $VERSION_OUT: could not type into composer"
  capture_until approved 'PI_WORKER_TRUST_COMPOSER'
  if grep -q 'Trust project folder' "$RUN_DIR/approved.txt"; then
    fail "$HARNESS $VERSION_OUT: approved launch still shows the trust dialog"
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-session -t approved || fail "could not stop approved launch"
  cmp -s "$RUN_DIR/trust-before" "$PI_DIR/trust.json" || fail "$HARNESS $VERSION_OUT: approval persisted trust"
  cmp -s "$RUN_DIR/settings-before" "$PI_DIR/settings.json" || fail "$HARNESS $VERSION_OUT: approval changed settings"
  pass "$HARNESS: approved task reaches the composer without changing trust.json or settings.json"

  # Do not reset either store: a persisted task or parent approval must fail here.
  expect_prompt next-process "$TASK"
  pass "$HARNESS: the same task prompts again in a new process without approval"
  expect_prompt parent "$PARENT"
  expect_prompt sibling "$SIBLING"
  pass "$HARNESS: parent and sibling still prompt without approval"
  cmp -s "$RUN_DIR/trust-before" "$PI_DIR/trust.json" || fail "$HARNESS $VERSION_OUT: trust store changed"
  cmp -s "$RUN_DIR/settings-before" "$PI_DIR/settings.json" || fail "$HARNESS $VERSION_OUT: settings changed"
  CHECKED=$((CHECKED + 1))
}

for HARNESS in pi pi-signed; do check_harness; done
for f in trust.json settings.json; do
  if [ -e "$LAB/real-before/$f" ]; then
    cmp -s "$LAB/real-before/$f" "$REAL_PI_DIR/$f" || fail "real $REAL_PI_DIR/$f changed during the guard"
  elif [ -e "$REAL_PI_DIR/$f" ]; then
    fail "real $REAL_PI_DIR/$f appeared during the guard"
  fi
done
if [ "$AVAILABLE" -eq 0 ]; then
  # Let the shared gate decide whether absent tools skip or fail when requested.
  fm_live_gate default-on FM_PI_WORKTREE_TRUST_LIVE pi
fi
if [ "$CHECKED" -eq 0 ]; then
  echo 'skip: live: no installed Pi surface supports process-local approval'
  exit 0
fi
printf '# all fm-pi-worktree-trust-live-e2e checks passed (%s checked)\n' "$CHECKED"
