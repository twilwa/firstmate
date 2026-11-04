#!/usr/bin/env bash
# Opt-in, token-free real Pi 1.4.0 compaction proof. No live tmux server:
# fm-spawn uses fixture tmux; only the isolated RPC children run real Pi.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_PI_COMPACTION_LIVE node pi

# Resolve dispatchers before clearing HOME, including Node: otherwise a mise
# shim could install another Node into the throwaway home. No Pi is run here.
resolve_executable() {
  local executable resolved
  executable=$(type -P "$1")
  resolved=$(node -e 'console.log(require("node:fs").realpathSync(process.argv[1]))' "$executable")
  if [ "${resolved##*/}" = mise ]; then
    executable=$("$(type -P mise)" which "$1")
  fi
  printf '%s\n' "$executable"
}
PI_EXECUTABLE=$(resolve_executable pi)
NODE_EXECUTABLE=$(resolve_executable node)
TMP_ROOT=$(fm_test_tmproot fm-pi-compaction-live)
home="$TMP_ROOT/fm-home"
project="$TMP_ROOT/project"
wt="$TMP_ROOT/wt"
fm_test_spawn_home "$home" pi
fm_git_worktree "$project" "$wt" compact
fm_test_spawn_brief "$home" compact
fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake")
cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || printf '1.4.0\n'
exit 0
SH
chmod +x "$fakebin/pi"
out=$(FM_STREAM_SILENT_MAX_SECS=300 fm_test_run_spawn "$home" "$wt" "$fakebin" compact "$project" pi --mode no-mistakes --yolo off) \
  || fail "could not generate Pi extension: $out"
# Retain only gate identity, not ambient provider credentials or Pi discovery.
clean_env=(env -i)
for name in NO_MISTAKES_GATE CODEX_MANAGED_BY_NPM CODEX_MANAGED_PACKAGE_ROOT; do
  [ "${!name+x}" != x ] || clean_env+=("$name=${!name}")
done
"${clean_env[@]}" PATH="$PATH" HOME="$TMP_ROOT/driver-home" \
  XDG_CONFIG_HOME="$TMP_ROOT/driver-config" PI_CODING_AGENT_DIR="$TMP_ROOT/driver-agent" \
  REAL_PI_AGENT="$HOME/.pi/agent" PI_EXECUTABLE="$PI_EXECUTABLE" \
  COMPACT_ROOT="$TMP_ROOT" COMPACT_STATE="$home/state" COMPACT_CWD="$wt" \
  COMPACT_EXTENSION="$home/state/compact.pi-ext.ts" \
  "$NODE_EXECUTABLE" "$ROOT/tests/fm-pi-compaction-live.mjs" || fail "real Pi compaction guard failed"
pass "real Pi 1.4.0 post-settlement compaction, continuation, idle success, error and abort with isolated configuration"
