#!/usr/bin/env bash
# Shared fake-hc CLI fixture for adapter and lifecycle control tests.
# Callers source tests/lib.sh and supply TMP_ROOT and FM_TEST_ROOT.
# No invocation delegates to a real hc binary.

# Answers get from <dir>/<address>.json (or <address>.exit), ls/run from
# their JSON files, and removes terminals on rm unless rm-sticks exists.
# Every call records HC_SESSION and HC_SOCKET. Lifecycle flags opt into
# shell/agent transitions; they model CLI effects, not classifier internals.
make_hc_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/hc" <<'SH'
#!/usr/bin/env bash
set -u
D="${FAKE_HC_DIR:?}"
{
  printf 'HC_SESSION=%s HC_SOCKET=%s' "${HC_SESSION:-}" "${HC_SOCKET:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$D/log"
cmd=${1:-}
last=""
for a in "$@"; do last=$a; done
case "$cmd" in
  --version) printf 'hc %s\n' "${FAKE_HC_VERSION:-0.1.14}" ;;
  server) printf '{"live":0}\n' ;;
  connect)
    IFS= read -r _req || true
    printf '{"jsonrpc":"2.0","id":1,"result":{"generation":%s}}\n' "${FAKE_HC_GENERATION:-1}"
    ;;
  ls) cat "$D/ls.json" 2>/dev/null || printf '{"terminals":[]}\n' ;;
  run) cat "$D/run.json" ;;
  get)
    [ -f "$D/$last.exit" ] && exit "$(cat "$D/$last.exit")"
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    cat "$D/$last.json"
    ;;
  rm) [ -e "$D/rm-sticks" ] || rm -f "$D/$last.json"; printf '{}\n' ;;
  read) if [ -f "$D/screen" ]; then cat "$D/screen"; else printf 'screen of %s\n' "$last"; fi ;;
  send)
    if [ -f "$D/send.exit" ]; then
      printf '{"error":{"kind":"%s"}}\n' "$(cat "$D/send.kind" 2>/dev/null || echo blocked)" >&2
      exit "$(cat "$D/send.exit")"
    fi
    if [ -f "$D/relaunch-starts-agent" ]; then
      payload=$last
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      case "$payload" in
        *'Firstmate operational input waiting: read'*)
          jq '.foreground = {name:"claude",argv:["claude"],pid:1,cwd:.cwd}' "$D/t2.json" > "$D/started.json"
          mv "$D/started.json" "$D/t2.json"
          ;;
      esac
    fi
    if [ -f "$D/exit-stops-agent" ] && [ "$last" = /exit ]; then
      jq '.foreground = {name:"bash",argv:["/bin/bash"],pid:1,cwd:.cwd}' "$D/t2.json" > "$D/stopped.json"
      mv "$D/stopped.json" "$D/t2.json"
    fi
    cat "$D/send.json" 2>/dev/null || printf '{"started":true,"wait":{"status":"working"}}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fb/hc"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> -> sets D, FB, HOMEDIR
  D="$TMP_ROOT/$1"
  mkdir -p "$D"
  FB=$(make_hc_fakebin "$D")
  HOMEDIR="$D/home"
  mkdir -p "$HOMEDIR"
}

# FM_HC_BIN pins the stub even with a real hc installed. CASE_HC_BIN
# overrides it for binary-resolution tests. HOMETAG is available to scripts.
hc_shell() {  # <script>
  FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HC_BIN=${CASE_HC_BIN:-$FB/hc} \
    FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$FM_TEST_ROOT \
    HC_SESSION=fmtest bash -c '
      . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
      fm_backend_source hc || { echo "source failed" >&2; exit 90; }
      HOMETAG=$(fm_backend_hometag)
      '"$1"
}

write_terminal() {  # <dir> <address> <state> <label> <home> <fg-name> <fg-argv0>
  jq -n --arg a "$2" --arg s "$3" --arg t "$4" --arg h "$5" --arg n "$6" --arg v "$7" '
    {address: $a, state: $s, labels: {"firstmate.task": $t, "firstmate.home": $h},
     cwd: "/start", foreground: (if $n == "" then null else {name: $n, argv: [$v], cwd: "/live", pid: 1} end)}' \
    > "$1/$2.json"
}

hometag_of() {
  FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$FM_TEST_ROOT bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_source hc; fm_backend_hometag'
}

expect_refused() {  # <command...>
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "expected a refusal from: ${*: -1}"
}
