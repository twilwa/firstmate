#!/usr/bin/env bash
# A detached server must not hold the redirected caller's output pipe open.
set -eu
ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
TMP=$(mktemp -d)
cleanup() {
  if [ -f "$TMP/pid" ]; then kill "$(< "$TMP/pid")" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
BASH_BIN=$(type -P bash)
SLEEP_BIN=$(type -P sleep)
export SLEEP_BIN
mkdir "$TMP/bin"
printf '#!%s\n' "$BASH_BIN" > "$TMP/bin/herdr"
cat >> "$TMP/bin/herdr" <<'SH'
set -eu
case "$1" in
  status)
    if [ -f "$FIXTURE/pid" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  server)
    printf '%s\n' "$$" > "$FIXTURE/pid"
    exec "$SLEEP_BIN" 30
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/herdr"
head -n2 "$TMP/bin/herdr"
# The redirection recreates remote-doctor's saved stdout/stderr descriptors.
# timeout bounds the pipe read, not the intentionally long-lived fake server.
# Variables in the command string belong to the child shell.
# shellcheck disable=SC2016
if ! FIXTURE="$TMP" PATH="$TMP/bin:$PATH" fm_run_timed 5 "$BASH_BIN" -c '
  output=$(
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_server_ensure eof-test >/dev/null 2>&1 || exit
    printf "ready\n"
  )
  printf "%s" "$output" > "$FIXTURE/output"
' _ "$ROOT"; then
  echo 'FAIL: server-ensure caller did not reach EOF within five seconds' >&2
  exit 1
fi
[ "$(< "$TMP/output")" = ready ] || { echo 'FAIL: missing readiness result' >&2; exit 1; }
kill -0 "$(< "$TMP/pid")" || { echo 'FAIL: server did not outlive caller' >&2; exit 1; }
echo 'PASS: caller reaches EOF while detached server remains running'
