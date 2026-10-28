#!/usr/bin/env bash
# tests/fm-kimi-delivery-live-e2e.test.sh - opt-in guard proving the INSTALLED
# Kimi Code CLI's submitted-brief panes are read the way bin/fm-spawn.sh's
# delivery gate reads them: an empty composer, with and without a cursor, plus
# bin/fm-kimi-delivery-lib.sh's evidence that Kimi took the message, both while
# the turn runs and once it has ended.
#
# Why this file exists: the evidence is vendor-rendered. Kimi Code CLI 2.3.x
# stopped echoing a submitted message behind `✨` and draws its footer directly
# under the composer box, and Herdr launches on 2.3.1 and 2.3.3 never confirmed
# a worker that was already running. The portable regressions in
# tests/fm-kimi-harness.test.sh and tests/fm-composer-lib.test.sh replay panes
# recorded from 2.3.3 (tests/captures/kimi-code-2.3.3/README.md); this guard
# asks the installed binary and fails naming it and its version. The
# token-free shapes (ready, typed, refused) are
# tests/fm-kimi-trust-prompt-live-e2e.test.sh's.
#
# It submits one short brief to a real, logged-in Kimi, so it spends model
# tokens and is opt-in: FM_KIMI_DELIVERY_LIVE=1. Kimi runs with the operator's
# own login and configuration in a private tmux server, from a disposable
# directory outside any git checkout whose folder prompt it answers, so the
# operator's trust store gains that directory's entry. Run it after every Kimi
# upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KIMI_DELIVERY_LIVE tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Mirror bin/fm-spawn.sh's own resolution order so the guard covers the binary
# firstmate would launch: PATH first, then the installer's default location.
KIMI_BIN=$(type -P kimi 2>/dev/null || true)
if [ -z "$KIMI_BIN" ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
  KIMI_BIN=$HOME/.kimi-code/bin/kimi
fi
[ -n "$KIMI_BIN" ] || { printf 'not ok - FM_KIMI_DELIVERY_LIVE was requested but kimi is not installed\n' >&2; exit 1; }
VERSION=$("$KIMI_BIN" --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$VERSION" ] || VERSION=unknown
WHO="kimi $VERSION"

REAL_TMUX=$(type -P tmux)
SOCKET="fm-kimi-delivery-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-kimi-delivery.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

if git -C "$LAB" rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "$WHO: the lab $LAB is inside a git checkout, whose project files Kimi would read; set TMPDIR outside any checkout"
fi

mkdir -p "$LAB/shim" "$LAB/work"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-kimi-trust-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-kimi-delivery-lib.sh"

cat > "$LAB/brief.md" <<'EOF'
This is a short delivery check. Run the shell command `sleep 8 && echo DELIVERY-OK` once, then reply with the single word FINISHED. Do nothing else.
EOF
POINTER="Read the brief at $LAB/brief.md and follow it exactly."

CURSORLESS_CAPS=$'styled=1\ncursor=0\nidentity=1\nrows=40'
cursorless_state() {
  fm_composer_classify_screen "$CURSORLESS_CAPS" "$("$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t kimi)"
}
composer_empty_both_ways() {
  [ "$(fm_backend_composer_state tmux kimi 2>/dev/null)" = empty ] && [ "$(cursorless_state)" = empty ]
}

"$REAL_TMUX" -L "$SOCKET" new-session -d -s kimi -x 120 -y 40 -c "$LAB/work" \
  -- env -u KIMI_CODE_TRUST_WORKSPACE KIMI_CODE_NO_AUTO_UPDATE=1 "$KIMI_BIN" --auto \
  || fail "$WHO: could not launch a private tmux session"

# Ready: the folder prompt answered as the spawn answers it, then an empty
# composer on two consecutive polls.
ready=0
PANE=
for _ in $(seq 1 300); do
  PANE=$(fm_backend_visible_capture tmux kimi 2>/dev/null || true)
  if kimi_trust_dialog_is_visible "$PANE"; then
    kimi_pane_announces_project_mcp_servers "$PANE" \
      && fail "$WHO: the lab directory's folder prompt announces project MCP servers; visible pane:
$PANE"
    fm_backend_send_key tmux kimi Enter || fail "$WHO: the folder prompt could not be answered"
    ready=0
  elif ! kimi_trust_marker_is_present "$PANE" && composer_empty_both_ways; then
    ready=$((ready + 1))
    [ "$ready" -lt 2 ] || break
  else
    ready=0
  fi
  sleep 0.2
done
[ "$ready" -ge 2 ] || fail "$WHO: no ready composer within 60s; visible pane:
$PANE"

fm_backend_tmux_send_literal kimi "$POINTER" || fail "$WHO: the pointer could not be typed"
sleep 1
fm_backend_send_key tmux kimi Enter || fail "$WHO: Enter could not be sent"

# Working: the spawn's verdict must arrive while the turn still runs.
confirmed=0
for _ in $(seq 1 150); do
  PANE=$(fm_backend_capture tmux kimi 120 2>/dev/null || true)
  if composer_empty_both_ways && kimi_pane_shows_brief_taken "$PANE"; then
    confirmed=1
    break
  fi
  sleep 0.2
done
[ "$confirmed" -eq 1 ] || fail "$WHO: a submitted brief was not confirmed within 30s (composer: $(fm_backend_composer_state tmux kimi 2>/dev/null) with a cursor, $(cursorless_state) without); pane:
$PANE"
signals=
case "$PANE" in *'✨'*'Read the brief at'* | *'Read the brief at'*'✨'*) signals="$signals sparkle-echo" ;; esac
printf '%s\n' "$PANE" | grep -Eq '^[[:space:]]*❯[[:space:]]+Read the brief at' && signals="$signals prompt-echo"
printf '%s\n' "$PANE" | grep -qiE 'context:[[:space:]]*[0-9.]*[1-9][0-9.]*[[:space:]]*%' && signals="$signals context-usage"
printf '%s\n' "$PANE" | fm_busy_lines_match kimi && signals="$signals spinner"
note "$WHO: confirmed while working on:$signals"
pass "$WHO: a submitted brief is confirmed while the turn runs, with an empty composer read with and without a cursor"

# Idle after the turn: the evidence stays and the composer still reads empty.
ended=0
for _ in $(seq 1 600); do
  PANE=$(fm_backend_capture tmux kimi 120 2>/dev/null || true)
  if printf '%s\n' "$PANE" | grep -q 'FINISHED' && ! printf '%s\n' "$PANE" | fm_busy_lines_match kimi; then
    ended=1
    break
  fi
  sleep 0.2
done
[ "$ended" -eq 1 ] || fail "$WHO: the brief's turn did not end within 120s; pane:
$PANE"
composer_empty_both_ways || fail "$WHO: the idle composer after the turn reads $(fm_backend_composer_state tmux kimi 2>/dev/null) with a cursor and $(cursorless_state) without, expected empty; pane:
$PANE"
kimi_pane_shows_brief_taken "$PANE" || fail "$WHO: the idle pane after the turn lost its delivery evidence; pane:
$PANE"
pass "$WHO: after the turn the composer still reads empty both ways and the pane still shows the brief was taken"
