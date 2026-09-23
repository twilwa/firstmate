#!/usr/bin/env bash
# Opt-in credentialed Codex regression for the tracked native hooks and the
# synchronous Stop-hook watcher park.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.codex-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/codex.jsonl"
HOOK_LOG="$HOME_DIR/state/native-hooks.jsonl"
CODEX_VERSION=$(codex --version)
EVENT_PID=

cleanup() {
  [ -z "$EVENT_PID" ] || kill "$EVENT_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.codex/hooks.json" "$PROJECT/.codex/hooks.json"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/live.meta"

cat > "$PROJECT/bin/fm-codex-hook-recorder.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat 2>/dev/null || true)
printf '%s\n' "$payload" >> "$FM_HOME/state/native-hooks.jsonl"
SH
chmod +x "$PROJECT/bin/fm-codex-hook-recorder.sh"

# shellcheck disable=SC2016 # Command substitution is intentionally deferred to the hook shell.
RECORDER='"$(pwd -P)"/bin/fm-codex-hook-recorder.sh'
jq --arg command "$RECORDER" '
  .hooks.SessionStart[0].hooks += [{type:"command", command:$command, timeout:30}]
  | .hooks.PreToolUse[0].hooks += [{type:"command", command:$command, timeout:30}]
  | .hooks.Stop[0].hooks += [{type:"command", command:$command, timeout:30}]
' "$PROJECT/.codex/hooks.json" > "$PROJECT/.codex/hooks.json.tmp" \
  || fail "could not add the isolated native hook recorder"
mv "$PROJECT/.codex/hooks.json.tmp" "$PROJECT/.codex/hooks.json"

# Publish one real watcher event only after the Stop hook has claimed the park
# and the actual watcher has emitted a beacon. This is outside the Codex model
# process, so a successful continuation proves the sleeping hook returned the
# event to its parent turn rather than the model polling a file.
(
  i=0
  while [ "$i" -lt 240 ]; do
    if [ -s "$HOME_DIR/state/.codex-park-owner" ] && [ -e "$HOME_DIR/state/.last-watcher-beat" ]; then
      printf 'done: isolated live watcher event\n' > "$HOME_DIR/state/live.status"
      exit 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  rm -f "$HOME_DIR/state/live.meta"
  exit 1
) &
EVENT_PID=$!

# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After the checkpoint returns, reply with exactly `PARK_READY primary harness codex` if the session-start context identified the primary as codex, otherwise reply with exactly `PARK_READY unknown`. If a Stop-hook watcher wake then continues this same turn, run `bin/fm-wake-drain.sh`, handle its live.status wake, run the exact WAKE_ACK_REQUIRED command it prints, run `rm -f "$FM_HOME/state/live.meta"`, and reply with exactly `WAKE_HANDLED`.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "Codex credentialed Stop-park turn failed: $(tail -20 "$TRANSCRIPT")"

wait "$EVENT_PID" || fail "the native Stop-hook park never established a live watcher before the event deadline"
EVENT_PID=

grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the real foreground checkpoint result"
grep -F 'PARK_READY primary harness codex' "$TRANSCRIPT" >/dev/null \
  || fail "native SessionStart did not identify the detached Codex hook host"
grep -F 'WAKE_HANDLED' "$TRANSCRIPT" >/dev/null \
  || fail "the sleeping Stop hook did not return the actionable event to its parent turn"

jq -e 'select(.hook_event_name == "SessionStart" and .source == "startup")' "$HOOK_LOG" >/dev/null \
  || fail "installed Codex did not fire native SessionStart"
[ -s "$HOME_DIR/state/.lock" ] \
  || fail "native SessionStart did not acquire the empty-state session lock"
jq -e 'select(.hook_event_name == "PreToolUse" and .tool_name == "Bash" and (.tool_input.command | contains("fm-watch-checkpoint.sh --seconds 1")))' "$HOOK_LOG" >/dev/null \
  || fail "installed Codex did not match the foreground exec as Bash"
jq -e 'select(.hook_event_name == "Stop" and .stop_hook_active == false)' "$HOOK_LOG" >/dev/null \
  || fail "installed Codex did not fire the initial Stop"
jq -e 'select(.hook_event_name == "Stop" and .stop_hook_active == true)' "$HOOK_LOG" >/dev/null \
  || fail "installed Codex did not fire the continued Stop with stop_hook_active=true"
[ ! -e "$HOME_DIR/state/live.meta" ] || fail "the continued turn did not finish handling its fixture lane"

if jq -e 'select(.hook_event_name == "PreToolUse" and .tool_name == "Bash" and (.tool_input.command | contains("fm-watch-arm.sh")))' "$HOOK_LOG" >/dev/null; then
  fail "the model issued an arm command instead of the synchronous Stop hook owning it"
fi

printf 'ok - %s native SessionStart and Bash matching fired; quiet expiry reached Stop, the synchronous hook parked a real watcher, and its event resumed the same turn through both Stop states\n' "$CODEX_VERSION"
