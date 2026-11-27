#!/usr/bin/env bash
# Tests for bin/fm-night-check.sh, the overnight stop-and-health check and the
# herdr-core (hc) night guard.
#
# Every case runs in an isolated temp home with stubbed quota-axi, gh, and
# herdr-core binaries plus deterministic FM_NIGHT_NOW_EPOCH and
# FM_PROC_ROOT_OVERRIDE fixtures so the suite never touches a live account,
# real forge API, real host load, or real hc core.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-night-check.sh"
CAPACITY="$ROOT/bin/fm-capacity.sh"
PR_REVIEW="$ROOT/bin/fm-pr-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-night-check)

# Reference epochs in America/Los_Angeles (UTC-8 in November standard time):
# 2026-11-27 01:00:00 PST = 2026-11-27T09:00:00Z = 1795770000
# 2026-11-27 06:35:00 PST = 2026-11-27T14:35:00Z = 1795790100
# 2026-11-27 07:35:00 PST = 2026-11-27T15:35:00Z = 1795793700
EPOCH_IN_WINDOW=1795770000
EPOCH_PAST_CUTOFF=1795790100
EPOCH_AFTER_END=1795793700
EPOCH_NIGHT_START=1795762800 # 2026-11-26 23:00:00 PST

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/proc" "$home/fakebin"
  printf '1.50 1.20 1.00 1/120 1234\n' > "$home/proc/loadavg"
  printf 'MemTotal:       32768000 kB\nMemAvailable:   24576000 kB\n' > "$home/proc/meminfo"
  printf '8\nreserve-flag %s/state/night.reserve night stop\n' "$home" > "$home/config/lane-capacity"
  printf '%s\n' "$home"
}

fake_quota_axi() {  # <dir> <five_rem> <week_rem> [stale_bool] [state_status]
  local dir=$1 five_rem=$2 week_rem=$3 stale=${4:-false} st=${5:-fresh} payload
  mkdir -p "$dir"
  payload=$(jq -cn \
    --argjson f "$five_rem" \
    --argjson w "$week_rem" \
    --argjson stale "$stale" \
    --arg st "$st" '
    {
      generatedAt: "2026-11-27T09:00:00Z",
      schemaVersion: 5,
      providers: [{
        provider: "claude",
        label: "Claude",
        source: "oauth",
        plan: "max",
        account: {accountId: "acct", email: "a@example.com", organization: "org", identityStatus: "verified"},
        windows: [
          {id: "five_hour", label: "5h", kind: "five_hour", percentUsed: (100 - $f), percentRemaining: $f},
          {id: "seven_day", label: "week", kind: "weekly", percentUsed: (100 - $w), percentRemaining: $w}
        ],
        attempts: [],
        state: {status: $st, stale: $stale, refreshedAt: "2026-11-27T09:00:00Z", sourcesTried: []},
        quotaSemantics: {status: "known", description: "d", effectiveAvailability: [{scope: "all_models", status: "known", effectivePercentRemaining: $f, boundedBy: ["five_hour", "seven_day"], limitingWindowIds: ["five_hour"], runway: {status: "through_reset"}}]}
      }]
    }')
  {
    printf '#!/usr/bin/env bash\n'
    printf "cat <<'JSON'\n%s\nJSON\n" "$payload"
  } > "$dir/quota-axi"
  chmod +x "$dir/quota-axi"
}

fake_quota_axi_raw() {  # <dir> <json>
  local dir=$1 json=$2
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf "cat <<'JSON'\n%s\nJSON\n" "$json"
  } > "$dir/quota-axi"
  chmod +x "$dir/quota-axi"
}

fake_gh_rate_limit() {
  local dir=$1 remaining=$2
  mkdir -p "$dir"
  cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "api" ] && [ "\${2:-}" = "rate_limit" ]; then
  printf '{"resources":{"core":{"limit":5000,"used":%d,"remaining":%d,"reset":1795800000}}}\n' \$((5000 - $remaining)) "$remaining"
  exit 0
fi
exit 1
EOF
  chmod +x "$dir/gh"
}

seed_healthy_stubs() {
  local home=$1
  fake_quota_axi "$home/fakebin" 80 70
  fake_gh_rate_limit "$home/fakebin" 4200
}

run_night_check() {
  local home=$1 now=$2
  shift 2
  env \
    -u FM_BACKEND -u FM_HC_BIN -u FM_HC_SOCKET \
    -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SOCKET -u HC_SESSION -u HC_SCOPE \
    -u FM_CREW_STATE_BIN \
    PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" \
    FM_NIGHT_NOW_EPOCH="$now" \
    FM_PROC_ROOT_OVERRIDE="$home/proc" \
    "$CHECK" "$@" </dev/null
}

write_ship_meta() {  # <home> <id> <spawn_epoch> [extra_lines]
  local home=$1 id=$2 ep=$3 extra=${4:-}
  {
    printf 'kind=ship\n'
    printf 'spawn_gen=s%d.1\n' "$ep"
    [ -z "$extra" ] || printf '%s\n' "$extra"
  } > "$home/state/$id.meta"
}

assert_no_reserve_flag() {  # <home> <message>
  [ ! -e "$1/state/night.reserve" ] || fail "$2"
}

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "fm-night-verdict.v1" "--help documents the verdict JSON schema"
  assert_contains "$out" "hc-guard" "--help documents hc-guard"
  rc=0
  out=$("$CHECK" bogus-subcommand 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown subcommand must exit 2"
  pass "fm-night-check: help and usage"
}

test_healthy_night_verdict_and_machine_readable_output() {
  local home out stored rc=0
  home=$(make_home healthy)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "healthy check --json must exit 0"
  assert_equals "fm-night-verdict.v1" "$(printf '%s\n' "$out" | jq -r '.schema')" "schema matches fm-night-verdict.v1"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "healthy verdict is continue"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.dispatch')" "dispatch allowed"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.claude')" "claude allowed"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.merge')" "merge allowed"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.validation')" "validation allowed"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.two_hour_default')" "two-hour default allowed during active healthy night"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.tripped | length')" "no tripped conditions"
  [ ! -e "$home/state/night-stop.json" ] || fail "healthy check must not write night-stop.json"
  [ ! -e "$home/state/night.reserve" ] || fail "healthy check must not set reserve-flag"

  # P3 consumes the latest stored verdict without re-polling external sources
  stored=$(FM_HOME="$home" "$CHECK" verdict --json 2>&1) || fail "verdict --json must read stored verdict"
  assert_equals "continue" "$(printf '%s\n' "$stored" | jq -r '.verdict')" "stored verdict matches latest check"
  assert_equals "true" "$(printf '%s\n' "$stored" | jq -r '.allow.two_hour_default')" "stored verdict exposes two_hour_default while night is active"
  pass "fm-night-check: healthy night verdict and stored machine-readable consumption"
}

test_two_hour_default_gated_on_active_night_and_transitions() {
  local home out stored rc=0
  home=$(make_home default_gate)
  seed_healthy_stubs "$home"

  # In-window check without an active night -> allow.two_hour_default is false
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "inactive in-window check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "inactive healthy in-window check reads continue"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.night_active')" "night_active is false without start"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.two_hour_default')" "two-hour default is false when no night is active"

  # Active night -> check sets allow.two_hour_default true
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "active check exits 0"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.two_hour_default')" "active healthy night allows two-hour default"

  # Immediately after end -> stored verdict keeps historical fields for P3,
  # but night_active and allow.two_hour_default become false
  run_night_check "$home" "$EPOCH_AFTER_END" end >/dev/null 2>&1 || fail "end must succeed"
  stored=$(FM_HOME="$home" "$CHECK" verdict --json 2>&1) || fail "verdict --json must still read historical verdict after end"
  assert_equals "continue" "$(printf '%s\n' "$stored" | jq -r '.verdict')" "stored historical verdict preserves verdict for morning board"
  assert_equals "false" "$(printf '%s\n' "$stored" | jq -r '.night_active')" "end marks stored verdict night_active=false"
  assert_equals "false" "$(printf '%s\n' "$stored" | jq -r '.allow.two_hour_default')" "end marks stored verdict allow.two_hour_default=false"

  # Immediately after a new start before its first check -> verdict --json
  # must not serve the earlier night's stored verdict
  run_night_check "$home" $((EPOCH_NIGHT_START + 86400)) start >/dev/null 2>&1 || fail "second start must succeed"
  rc=0
  out=$(FM_HOME="$home" "$CHECK" verdict --json 2>&1) || rc=$?
  expect_code 1 "$rc" "new start clears prior night verdict until first check runs"
  assert_contains "$out" "no stored night verdict" "verdict explains no verdict exists yet for the new night"
  pass "fm-night-check: allow.two_hour_default requires active night and transitions cleanly across end and new start"
}

test_night_window_last_dispatch_cutoff_is_level_and_sets_no_flag() {
  local home out rc=0
  home=$(make_home cutoff)
  seed_healthy_stubs "$home"
  cat > "$home/config/night-check" <<'EOF'
window-start 23:00
last-dispatch 06:30
window-end 07:30
timezone America/Los_Angeles
EOF
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  out=$(run_night_check "$home" "$EPOCH_PAST_CUTOFF" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "cutoff check must exit 0 with verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "past last-dispatch trips stop_dispatch"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.dispatch')" "dispatch disallowed"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.two_hour_default')" "two-hour default disallowed once stopped"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.night_window.status')" "night_window marked tripped"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.latched | length')" "the cut-off is a level condition and never latches"
  [ ! -e "$home/state/night-stop.json" ] || fail "a level condition must not write the durable stop record"
  assert_no_reserve_flag "$home" "a level condition must not set reserve-flag"
  assert_equals "absent" "$(printf '%s\n' "$out" | jq -r '.reserve_flag.state')" "verdict reports the reserve-flag absent"
  pass "fm-night-check: last-dispatch cutoff stops dispatch as a level condition without the reserve-flag"
}

test_night_window_ended_ends_night_without_flag() {
  local home out rc=0
  home=$(make_home window_end)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  out=$(run_night_check "$home" "$EPOCH_AFTER_END" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "post-window check must exit 0 with verdict"
  assert_equals "end_night" "$(printf '%s\n' "$out" | jq -r '.verdict')" "after window-end verdict is end_night"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.dispatch')" "dispatch disallowed"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.merge')" "merge disallowed"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.night_window.status')" "night_window tripped"
  assert_no_reserve_flag "$home" "window end is a level condition and must not set reserve-flag"
  pass "fm-night-check: window end produces end_night verdict"
}

test_check_outside_active_night_sets_nothing() {
  local home out rc=0
  home=$(make_home no_night)
  seed_healthy_stubs "$home"
  write_ship_meta "$home" t1 $((EPOCH_IN_WINDOW - 400))
  write_ship_meta "$home" t2 $((EPOCH_IN_WINDOW - 300))
  write_ship_meta "$home" t3 $((EPOCH_IN_WINDOW - 200))
  printf 'failed [at=%d]: a\n' $((EPOCH_IN_WINDOW - 300)) > "$home/state/t1.status"
  printf 'failed [at=%d]: b\n' $((EPOCH_IN_WINDOW - 200)) > "$home/state/t2.status"
  printf 'failed [at=%d]: c\n' $((EPOCH_IN_WINDOW - 100)) > "$home/state/t3.status"
  out=$(run_night_check "$home" "$EPOCH_AFTER_END" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "daytime check exits 0"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.night_active')" "no night is active"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.failure_streak.status')" "event condition still reads tripped"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.latched | length')" "nothing latches outside an active night"
  [ ! -e "$home/state/night-stop.json" ] || fail "a check outside an active night must not write the stop record"
  assert_no_reserve_flag "$home" "a check outside an active night must never set reserve-flag"
  pass "fm-night-check: a check outside an active night latches nothing and sets no reserve-flag"
}

test_malformed_config_dangling_symlink_and_bad_timezone_fail_closed() {
  local home out rc=0

  # Invalid time syntax
  home=$(make_home bad_config)
  seed_healthy_stubs "$home"
  printf 'window-start not-a-time\n' > "$home/config/night-check"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "malformed config still emits fail-closed verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "malformed config stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.night_window.status')" "malformed config reports night_window unknown"

  # Dangling symlink at config/night-check
  home=$(make_home dangling_config)
  seed_healthy_stubs "$home"
  ln -s "$home/config/missing-target" "$home/config/night-check"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "dangling config symlink emits fail-closed verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "dangling config symlink stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.night_window.status')" "dangling config symlink reports night_window unknown"

  # Nonexistent IANA timezone
  home=$(make_home bad_tz)
  seed_healthy_stubs "$home"
  printf 'timezone America/NoSuchCity\n' > "$home/config/night-check"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "bad timezone emits fail-closed verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "nonexistent IANA timezone stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.night_window.status')" "nonexistent IANA timezone reports night_window unknown"
  pass "fm-night-check: malformed config, dangling symlink, and nonexistent timezone fail closed as unknown"
}

test_claude_quota_floors_boundaries_and_config_bounds() {
  local home out rc=0 admit_rc=0

  # Equality at 25% -> continue (strict < 25)
  home=$(make_home quota_eq25)
  fake_quota_axi "$home/fakebin" 25 25
  fake_gh_rate_limit "$home/fakebin" 4200
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "quota == 25% check must exit 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "25% remaining continues (strict < 25)"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.claude_quota.status')" "25% remaining is ok"

  # Weekly 20% (< 25%) -> stop_claude only; non-Claude builders still admitted
  home=$(make_home quota_20)
  fake_quota_axi "$home/fakebin" 80 20
  fake_gh_rate_limit "$home/fakebin" 4200
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "quota <25% check must exit 0"
  assert_equals "stop_claude" "$(printf '%s\n' "$out" | jq -r '.verdict')" "weekly 20% trips stop_claude"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.dispatch')" "non-Claude dispatch remains allowed"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.claude')" "Claude work disallowed"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.validation')" "Claude validation disallowed"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.claude_quota.status')" "claude_quota tripped"
  assert_no_reserve_flag "$home" "stop_claude must NOT set reserve-flag so non-Claude builders can dispatch"
  FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$home/proc" "$CAPACITY" --admit >/dev/null 2>&1 || admit_rc=$?
  expect_code 0 "$admit_rc" "fm-capacity.sh --admit still admits non-Claude work on stop_claude"

  # Equality at 12% -> stop_claude (strict < 12 for stop_dispatch)
  fake_quota_axi "$home/fakebin" 12 60
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "quota == 12% check must exit 0"
  assert_equals "stop_claude" "$(printf '%s\n' "$out" | jq -r '.verdict')" "12% remaining stops Claude only (strict < 12 for stop_dispatch)"

  # 11.9% (< 12%) -> stop_dispatch, and resets cleanly when window recovers
  fake_quota_axi "$home/fakebin" 11.9 60
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "quota 11.9% check must exit 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "11.9% trips stop_dispatch"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.dispatch')" "all dispatch disallowed below 12%"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.claude')" "Claude disallowed below 12%"
  fake_quota_axi "$home/fakebin" 90 60
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 600)) check --json 2>&1) || rc=$?
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "a reset Claude window gives continue"
  assert_no_reserve_flag "$home" "a recovered quota leaves no reserve-flag behind"

  # Config may raise floors (30 / 15), never weaken below 25 / 12
  home=$(make_home quota_floor_raised)
  fake_quota_axi "$home/fakebin" 28 60
  fake_gh_rate_limit "$home/fakebin" 4200
  printf 'claude-stop-claude-pct 30\nclaude-stop-all-pct 15\n' > "$home/config/night-check"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "raised floor check exits 0"
  assert_equals "stop_claude" "$(printf '%s\n' "$out" | jq -r '.verdict')" "raised 30% floor stops Claude at 28%"

  home=$(make_home quota_floor_weak_claude)
  seed_healthy_stubs "$home"
  printf 'claude-stop-claude-pct 20\n' > "$home/config/night-check"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "weakened claude floor emits fail-closed verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "weakening claude-stop-claude-pct below 25 stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.night_window.status')" "weakened claude floor reports config error"

  home=$(make_home quota_floor_weak_all)
  seed_healthy_stubs "$home"
  printf 'claude-stop-all-pct 10\n' > "$home/config/night-check"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "weakened stop-all floor emits fail-closed verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "weakening claude-stop-all-pct below 12 stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.night_window.status')" "weakened stop-all floor reports config error"
  pass "fm-night-check: Claude quota floors, equality boundaries, recovery, and config floor bounds"
}

test_claude_quota_partial_stale_and_unreadable_fail_closed() {
  local home out rc=0

  # Missing seven_day window -> unknown + stop_dispatch
  home=$(make_home quota_missing_week)
  fake_gh_rate_limit "$home/fakebin" 4200
  fake_quota_axi_raw "$home/fakebin" '{"generatedAt":"2026-11-27T09:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"max","account":{"accountId":"acct","email":"a@example.com","organization":"org","identityStatus":"verified"},"windows":[{"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":20,"percentRemaining":80}],"attempts":[],"state":{"status":"fresh","stale":false,"refreshedAt":"2026-11-27T09:00:00Z","sourcesTried":[]}}]}'
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "missing seven_day emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "missing seven_day stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.claude_quota.status')" "missing seven_day reports unknown"

  # Missing five_hour window -> unknown + stop_dispatch
  home=$(make_home quota_missing_5h)
  fake_gh_rate_limit "$home/fakebin" 4200
  fake_quota_axi_raw "$home/fakebin" '{"generatedAt":"2026-11-27T09:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"max","account":{"accountId":"acct","email":"a@example.com","organization":"org","identityStatus":"verified"},"windows":[{"id":"seven_day","label":"week","kind":"weekly","percentUsed":30,"percentRemaining":70}],"attempts":[],"state":{"status":"fresh","stale":false,"refreshedAt":"2026-11-27T09:00:00Z","sourcesTried":[]}}]}'
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "missing five_hour emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "missing five_hour stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.claude_quota.status')" "missing five_hour reports unknown"

  # Stale provider row -> unknown + stop_dispatch even with high percentages
  home=$(make_home quota_stale)
  fake_quota_axi "$home/fakebin" 80 70 true stale
  fake_gh_rate_limit "$home/fakebin" 4200
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "stale quota emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "stale quota stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.claude_quota.status')" "stale quota reports unknown"

  # Unreadable JSON -> unknown + stop_dispatch
  home=$(make_home quota_broken)
  fake_gh_rate_limit "$home/fakebin" 4200
  fake_quota_axi_raw "$home/fakebin" 'not-valid-json'
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "unreadable quota-axi still emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unreadable quota-axi stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.claude_quota.status')" "claude_quota reports unknown"
  pass "fm-night-check: partial, stale, and unreadable Claude quota readings fail closed as unknown"
}

test_github_api_below_floor_recovers_and_unreadable() {
  local home out rc=0
  home=$(make_home gh_low)
  fake_quota_axi "$home/fakebin" 80 70
  fake_gh_rate_limit "$home/fakebin" 999
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "low gh api check must exit 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "gh remaining 999 trips stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.github_api.status')" "github_api tripped"
  assert_no_reserve_flag "$home" "the GitHub floor is a level condition and must not set reserve-flag"

  # The hourly window resets above the floor: the next run continues
  fake_gh_rate_limit "$home/fakebin" 4800
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 600)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "recovered gh api check must exit 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "a recovered GitHub API reading gives continue"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.dispatch')" "dispatch resumes once the API recovers"

  home=$(make_home gh_broken)
  fake_quota_axi "$home/fakebin" 80 70
  cat > "$home/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$home/fakebin/gh"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "failing gh still emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "failing gh stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.github_api.status')" "github_api reports unknown"
  pass "fm-night-check: GitHub API floor pauses dispatch only while low, and an unreadable source fails closed"
}

write_review_ledger() {  # <home> <pr-num> <json>
  local home=$1 num=$2 json=$3
  mkdir -p "$home/data/pr-review-ledger"
  printf '%s\n' "$json" > "$home/data/pr-review-ledger/github--twilwa--bbchat--${num}.json"
}

test_failure_streak_latches_until_end() {
  local home out rc=0 admit_rc=0 admit_out
  home=$(make_home streak_trip)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  write_ship_meta "$home" t0 $((EPOCH_NIGHT_START + 50))
  write_ship_meta "$home" t1 $((EPOCH_NIGHT_START + 150))
  write_ship_meta "$home" t2 $((EPOCH_NIGHT_START + 250))
  write_ship_meta "$home" t3 $((EPOCH_NIGHT_START + 350))
  printf 'done [at=%d]: PR https://github.com/twilwa/bbchat/pull/1\n' $((EPOCH_NIGHT_START + 100)) > "$home/state/t0.status"
  printf 'failed [at=%d]: build broke\n' $((EPOCH_NIGHT_START + 200)) > "$home/state/t1.status"
  printf 'failed [at=%d]: test timeout\n' $((EPOCH_NIGHT_START + 300)) > "$home/state/t2.status"
  printf 'failed [at=%d]: lint error\n' $((EPOCH_NIGHT_START + 400)) > "$home/state/t3.status"

  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "failure streak check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "3 consecutive night ship failures trip stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.failure_streak.status')" "failure_streak tripped"
  assert_equals "3" "$(printf '%s\n' "$out" | jq -r '.conditions.failure_streak.details.streak')" "streak count is 3"
  assert_equals "failure_streak" "$(printf '%s\n' "$out" | jq -r '.latched[0].condition')" "the failure streak latches"
  [ -f "$home/state/night-stop.json" ] || fail "a latched event must write durable state/night-stop.json"
  assert_equals "fm-night-stop.v1" "$(jq -r '.schema' "$home/state/night-stop.json")" "stop record schema"
  [ -f "$home/state/night.reserve" ] || fail "a latched event must set reserve-flag from config/lane-capacity"
  assert_equals "set_by=fm-night-check" "$(sed -n 1p "$home/state/night.reserve")" "the reserve-flag names its owner"
  assert_contains "$(sed -n 2p "$home/state/night.reserve")" "token=" "the reserve-flag carries an ownership token"
  assert_equals "set_by_night_check" "$(printf '%s\n' "$out" | jq -r '.reserve_flag.state')" "verdict reports the flag as set by the check"
  admit_out=$(FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$home/proc" "$CAPACITY" --admit 2>&1) || admit_rc=$?
  expect_code 75 "$admit_rc" "fm-capacity.sh --admit must defer (75) once reserve-flag is set"
  assert_contains "$admit_out" "night stop" "fm-capacity refusal names the reserve-flag label"

  # A later done night ship clears the live streak, but the event stays latched
  write_ship_meta "$home" t4 $((EPOCH_NIGHT_START + 450))
  printf 'done [at=%d]: PR https://github.com/twilwa/bbchat/pull/2\n' $((EPOCH_NIGHT_START + 500)) > "$home/state/t4.status"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 600)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "healthy-after-trip check exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.failure_streak.status')" "the live failure_streak reading is ok"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "the latch keeps dispatch stopped"
  assert_equals "latched" "$(printf '%s\n' "$out" | jq -r '.tripped[] | select(.condition == "failure_streak") | .status')" "the latch is reported as latched"
  [ -f "$home/state/night.reserve" ] || fail "the reserve-flag survives a later healthy run"

  # end clears the check's own flag and keeps the stop record for the morning board
  run_night_check "$home" "$EPOCH_AFTER_END" end >/dev/null 2>&1 || fail "end must succeed"
  assert_no_reserve_flag "$home" "end must clear the reserve-flag the check set"
  [ -f "$home/state/night-stop.json" ] || fail "end must keep the stop record"
  assert_equals "failure_streak" "$(jq -r '.latched[0].condition' "$home/state/night-stop.json")" "the stop record keeps the latched event"
  admit_rc=0
  FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$home/proc" "$CAPACITY" --admit >/dev/null 2>&1 || admit_rc=$?
  expect_code 0 "$admit_rc" "fm-capacity.sh --admit admits again after end"

  # Without a check during the streak, a newer done night ship resets the streak
  home=$(make_home streak_reset)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  write_ship_meta "$home" t1 $((EPOCH_NIGHT_START + 100))
  write_ship_meta "$home" t2 $((EPOCH_NIGHT_START + 200))
  write_ship_meta "$home" t3 $((EPOCH_NIGHT_START + 300))
  write_ship_meta "$home" t4 $((EPOCH_NIGHT_START + 400))
  printf 'failed [at=%d]: a\n' $((EPOCH_NIGHT_START + 200)) > "$home/state/t1.status"
  printf 'failed [at=%d]: b\n' $((EPOCH_NIGHT_START + 300)) > "$home/state/t2.status"
  printf 'failed [at=%d]: c\n' $((EPOCH_NIGHT_START + 400)) > "$home/state/t3.status"
  printf 'done [at=%d]: PR https://github.com/twilwa/bbchat/pull/2\n' $((EPOCH_NIGHT_START + 500)) > "$home/state/t4.status"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "reset streak check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "newer done night ship resets failure streak"
  pass "fm-night-check: failure streak latches the reserve-flag until end, which clears it and keeps the stop record"
}

test_failure_streak_excludes_scouts_secondmates_and_pre_night_tasks() {
  local home out rc=0

  # Scouts, secondmates, and pre-night ships failing do not create a streak
  home=$(make_home streak_unrelated_fail)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  printf 'kind=scout\nspawn_gen=s%d.1\n' $((EPOCH_NIGHT_START + 100)) > "$home/state/sc1.meta"
  printf 'failed [at=%d]: scout failed\n' $((EPOCH_NIGHT_START + 200)) > "$home/state/sc1.status"
  printf 'kind=secondmate\nspawn_gen=s%d.1\n' $((EPOCH_NIGHT_START + 150)) > "$home/state/sm1.meta"
  printf 'failed [at=%d]: secondmate failed\n' $((EPOCH_NIGHT_START + 250)) > "$home/state/sm1.status"
  write_ship_meta "$home" old1 $((EPOCH_NIGHT_START - 3600))
  printf 'failed [at=%d]: daytime ship failed late\n' $((EPOCH_NIGHT_START + 300)) > "$home/state/old1.status"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "unrelated failures check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "scout, secondmate, and pre-night ship failures do not trip streak"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.conditions.failure_streak.details.streak')" "unrelated failures yield streak 0"

  # Interleaved scout/secondmate/pre-night done does NOT break a 3-night-ship streak
  home=$(make_home streak_interleaved_done)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  write_ship_meta "$home" n1 $((EPOCH_NIGHT_START + 100))
  printf 'failed [at=%d]: fail 1\n' $((EPOCH_NIGHT_START + 200)) > "$home/state/n1.status"
  printf 'kind=scout\nspawn_gen=s%d.1\n' $((EPOCH_NIGHT_START + 210)) > "$home/state/sc_ok.meta"
  printf 'done [at=%d]: scout report ready\n' $((EPOCH_NIGHT_START + 250)) > "$home/state/sc_ok.status"
  write_ship_meta "$home" n2 $((EPOCH_NIGHT_START + 260))
  printf 'failed [at=%d]: fail 2\n' $((EPOCH_NIGHT_START + 300)) > "$home/state/n2.status"
  write_ship_meta "$home" pre_ok $((EPOCH_NIGHT_START - 1800))
  printf 'done [at=%d]: daytime PR finished\n' $((EPOCH_NIGHT_START + 350)) > "$home/state/pre_ok.status"
  write_ship_meta "$home" n3 $((EPOCH_NIGHT_START + 360))
  printf 'failed [at=%d]: fail 3\n' $((EPOCH_NIGHT_START + 400)) > "$home/state/n3.status"
  printf 'kind=secondmate\nspawn_gen=s%d.1\n' $((EPOCH_NIGHT_START + 410)) > "$home/state/sm_ok.meta"
  printf 'done [at=%d]: secondmate done\n' $((EPOCH_NIGHT_START + 450)) > "$home/state/sm_ok.status"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "interleaved streak check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "interleaved scout/secondmate/pre-night done does not mask 3-ship streak"
  assert_equals "3" "$(printf '%s\n' "$out" | jq -r '.conditions.failure_streak.details.streak')" "streak counts only night-spawned ships"
  pass "fm-night-check: failure streak limits to night-spawned kind=ship tasks and ignores scouts, secondmates, and pre-night tasks"
}

test_corrupt_stop_record_stops_dispatch_without_latching_or_flag() {
  local home out rc=0
  home=$(make_home stop_corrupt)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  printf '{corrupt\n' > "$home/state/night-stop.json"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "corrupt stop record check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "corrupt stop record stops dispatch"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.latched | length')" "corrupt stop record does not fabricate a latch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.tripped[] | select(.condition == "night_stop_record") | .status')" "night_stop_record reported as unknown level failure"
  assert_no_reserve_flag "$home" "corrupt stop record must not set reserve-flag"
  assert_equals "{corrupt" "$(cat "$home/state/night-stop.json")" "corrupt stop record is left untouched for inspection"

  # Once repaired/removed, the next check recovers cleanly
  rm -f "$home/state/night-stop.json"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 300)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "recovered check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "repairing corrupt stop record recovers to continue"
  pass "fm-night-check: corrupt stop record fails closed without latching, overwriting, or setting reserve-flag"
}

test_end_clears_recorded_reserve_flag_even_after_config_change() {
  local home out rc=0
  home=$(make_home flag_config_change)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  write_ship_meta "$home" t1 $((EPOCH_NIGHT_START + 100))
  write_ship_meta "$home" t2 $((EPOCH_NIGHT_START + 200))
  write_ship_meta "$home" t3 $((EPOCH_NIGHT_START + 300))
  printf 'failed [at=%d]: a\n' $((EPOCH_NIGHT_START + 200)) > "$home/state/t1.status"
  printf 'failed [at=%d]: b\n' $((EPOCH_NIGHT_START + 300)) > "$home/state/t2.status"
  printf 'failed [at=%d]: c\n' $((EPOCH_NIGHT_START + 400)) > "$home/state/t3.status"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "trip check exits 0"
  [ -f "$home/state/night.reserve" ] || fail "original reserve-flag must be created"

  # Change config/lane-capacity to a different path (or remove reserve-flag altogether)
  printf '4\nreserve-flag %s/state/other.reserve other\n' "$home" > "$home/config/lane-capacity"
  run_night_check "$home" "$EPOCH_AFTER_END" end >/dev/null 2>&1 || fail "end must succeed"
  assert_no_reserve_flag "$home" "end must still remove the recorded reserve-flag even after config/lane-capacity changed"

  # If the file at the recorded path was replaced with a different token, end leaves it alone
  home=$(make_home flag_token_mismatch)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  write_ship_meta "$home" t1 $((EPOCH_NIGHT_START + 100))
  write_ship_meta "$home" t2 $((EPOCH_NIGHT_START + 200))
  write_ship_meta "$home" t3 $((EPOCH_NIGHT_START + 300))
  printf 'failed [at=%d]: a\n' $((EPOCH_NIGHT_START + 200)) > "$home/state/t1.status"
  printf 'failed [at=%d]: b\n' $((EPOCH_NIGHT_START + 300)) > "$home/state/t2.status"
  printf 'failed [at=%d]: c\n' $((EPOCH_NIGHT_START + 400)) > "$home/state/t3.status"
  run_night_check "$home" "$EPOCH_IN_WINDOW" check --json >/dev/null 2>&1 || fail "trip check must succeed"
  printf 'set_by=fm-night-check\ntoken=someone-else\n' > "$home/state/night.reserve"
  run_night_check "$home" "$EPOCH_AFTER_END" end >/dev/null 2>&1 || fail "end must succeed"
  [ -f "$home/state/night.reserve" ] || fail "end must not remove a reserve-flag whose token does not match"
  pass "fm-night-check: end clears recorded reserve-flags by exact path+token even after config edits"
}

test_foreign_reserve_flag_left_untouched() {
  local home out rc=0
  home=$(make_home foreign_flag)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  printf 'manual hold\n' > "$home/state/night.reserve"
  write_ship_meta "$home" t1 $((EPOCH_NIGHT_START + 100))
  write_ship_meta "$home" t2 $((EPOCH_NIGHT_START + 200))
  write_ship_meta "$home" t3 $((EPOCH_NIGHT_START + 300))
  printf 'failed [at=%d]: a\n' $((EPOCH_NIGHT_START + 200)) > "$home/state/t1.status"
  printf 'failed [at=%d]: b\n' $((EPOCH_NIGHT_START + 300)) > "$home/state/t2.status"
  printf 'failed [at=%d]: c\n' $((EPOCH_NIGHT_START + 400)) > "$home/state/t3.status"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "foreign-flag check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "the streak still stops dispatch"
  assert_equals "set_externally" "$(printf '%s\n' "$out" | jq -r '.reserve_flag.state')" "verdict reports the flag as set externally"
  assert_equals "manual hold" "$(cat "$home/state/night.reserve")" "the check must not overwrite a foreign flag"
  run_night_check "$home" "$EPOCH_AFTER_END" end >/dev/null 2>&1 || fail "end must succeed"
  assert_equals "manual hold" "$(cat "$home/state/night.reserve")" "end must leave a foreign flag in place"
  pass "fm-night-check: a reserve-flag someone else created is never overwritten or cleared"
}

test_missing_reserve_flag_config_warns() {
  local home out rc=0 human
  home=$(make_home no_flag_config)
  seed_healthy_stubs "$home"
  printf '4\n' > "$home/config/lane-capacity"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "check without reserve-flag config exits 0"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.reserve_flag.configured')" "reserve-flag is reported unconfigured"
  assert_contains "$(printf '%s\n' "$out" | jq -r '.warnings[]')" "stop_dispatch cannot be enforced" "verdict warns that stop_dispatch cannot be enforced"
  human=$(FM_HOME="$home" "$CHECK" verdict 2>&1) || fail "verdict must read the stored verdict"
  assert_contains "$human" "warning:" "the human verdict shows the warning"
  pass "fm-night-check: a missing reserve-flag config carries an explicit enforcement warning"
}

dev_ledger() {  # <num> <outcome> <recorded_epoch> [base_ref]
  local num=$1 outcome=$2 rec=$3 base_ref=${4:-} ready=allowed base_field=""
  [ "$outcome" = passed ] || ready=blocked
  if [ -n "$base_ref" ]; then
    base_field=$(printf ',"base_ref":"%s"' "$base_ref")
  fi
  printf '{"schema":"firstmate-pr-review-ledger.v1","task":"t-%s","url":"https://github.com/twilwa/bbchat/pull/%s","current_head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generations":[{"head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","created_epoch":%d,"risk":{"level":"low","reason":"small"},"checkpoints":[],"review_items":[],"attestations":[],"final_disposition":null,"merge_decision":{"decision":"merge","verified_head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","verified_epoch":%d},"post_merge_verifications":[{"applicability":"browser","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","outcome":"%s","ready_for_qa":"%s","recorded_epoch":%d%s}]}]}\n' \
    "$num" "$num" $((rec - 600)) $((rec - 300)) "$outcome" "$ready" "$rec" "$base_field"
}

test_dev_health_per_branch_recovery_legacy_fallback_and_producer() {
  local home out rc=0

  # 1. Cross-branch isolation: dev failed at 22:30, main passed later at 23:30 on same repo -> dev stays red
  home=$(make_home dev_cross_branch)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  write_review_ledger "$home" 1442 "$(dev_ledger 1442 failed $((EPOCH_NIGHT_START - 1800)) dev)"
  write_review_ledger "$home" 1443 "$(dev_ledger 1443 passed $((EPOCH_NIGHT_START + 1800)) main)"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "cross-branch dev health check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "a pass on main must not mask a failed dev target"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "dev_health stays tripped"
  assert_equals "https://github.com/twilwa/bbchat" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.details.failed_targets[0].repo')" "failed_targets names repo"
  assert_equals "dev" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.details.failed_targets[0].base_ref')" "failed_targets names target branch"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.merge')" "failed post-merge stops merges"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.two_hour_default')" "failed post-merge disallows two-hour default"
  assert_no_reserve_flag "$home" "a red dev target is a level stop and sets no reserve-flag"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.latched | length')" "a red dev target does not latch"
  assert_equals "dev_health" "$(jq -r '.history[0].condition' "$home/state/night-stop.json")" "the stop record history keeps the dev trip for the morning board"
  assert_equals "$EPOCH_IN_WINDOW" "$(jq -r '.history[0].first_tripped_epoch' "$home/state/night-stop.json")" "the history entry records when dev went red"

  # A later passing record on the same target branch clears the night's dev stop
  write_review_ledger "$home" 1444 "$(dev_ledger 1444 passed $((EPOCH_IN_WINDOW + 300)) dev)"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 600)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "dev recovery during the night exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "a later dev pass clears dev_health"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "fail then pass on the same branch continues"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.merge')" "a recovered dev allows merges again"
  assert_equals "1" "$(jq -r '.history | length' "$home/state/night-stop.json")" "the recovered dev trip stays in the stop history"
  assert_equals "continue" "$(jq -r '.verdict' "$home/state/night-stop.json")" "the stop record snapshot follows the recovered verdict"
  assert_equals "true" "$(jq -r '.allow.merge' "$home/state/night-stop.json")" "the stop record snapshot no longer blocks merges after recovery"
  assert_equals "$((EPOCH_IN_WINDOW + 600))" "$(jq -r '.last_checked_epoch' "$home/state/night-stop.json")" "the stop record is rewritten on the recovered check"
  assert_no_reserve_flag "$home" "a recovered dev target leaves no reserve-flag"

  # The same failure returning after a recovery is a new trip, not one continuous one
  write_review_ledger "$home" 1442 "$(dev_ledger 1442 failed $((EPOCH_IN_WINDOW + 900)) dev)"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 1200)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "dev failing again exits 0"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "dev_health trips again"
  assert_equals "2" "$(jq -r '.history | length' "$home/state/night-stop.json")" "a repeat failure after recovery adds a second history entry"
  assert_equals "$EPOCH_IN_WINDOW" "$(jq -r '.history[0].last_tripped_epoch' "$home/state/night-stop.json")" "the first trip ends before the recovery"
  assert_equals "$((EPOCH_IN_WINDOW + 1200))" "$(jq -r '.history[1].first_tripped_epoch' "$home/state/night-stop.json")" "the second trip starts at the repeat failure"

  # 2. Same-branch recovery: older dev failure followed by later dev pass -> dev is green
  home=$(make_home dev_same_branch_recover)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  write_review_ledger "$home" 1442 "$(dev_ledger 1442 failed $((EPOCH_NIGHT_START - 7200)) dev)"
  write_review_ledger "$home" 1450 "$(dev_ledger 1450 passed $((EPOCH_NIGHT_START - 3600)) dev)"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "same-branch recovery check exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "a later pass on dev supersedes an older dev failure"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "recovered dev continues"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.merge')" "recovered dev allows merges"

  # 3. Legacy records without base_ref resolve via bounded gh pr view --json baseRefName
  home=$(make_home dev_legacy_resolve)
  fake_quota_axi "$home/fakebin" 80 70
  cat > "$home/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ] && [ "${2:-}" = "rate_limit" ]; then
  printf '{"resources":{"core":{"limit":5000,"used":800,"remaining":4200,"reset":1795800000}}}\n'
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "${3:-}" in
    */pull/1442) printf '{"baseRefName":"dev"}\n'; exit 0 ;;
    */pull/1450) printf '{"baseRefName":"main"}\n'; exit 0 ;;
  esac
fi
exit 1
EOF
  chmod +x "$home/fakebin/gh"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  write_review_ledger "$home" 1442 "$(dev_ledger 1442 failed $((EPOCH_NIGHT_START - 1800)))"
  write_review_ledger "$home" 1450 "$(dev_ledger 1450 passed $((EPOCH_NIGHT_START + 600)))"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "legacy base_ref fallback check exits 0"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "legacy fallback preserves per-branch red state"
  assert_equals "dev" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.details.failed_targets[0].base_ref')" "legacy fallback identifies dev branch"

  # Resolved legacy base refs are cached durably: a later check makes no gh pr view call
  cat > "$home/fakebin/gh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "api" ] && [ "\${2:-}" = "rate_limit" ]; then
  printf '{"resources":{"core":{"limit":5000,"used":800,"remaining":4200,"reset":1795800000}}}\n'
  exit 0
fi
printf '%s\n' "\$*" >> "$home/gh-calls.log"
exit 1
EOF
  chmod +x "$home/fakebin/gh"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 300)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "cached legacy base_ref check exits 0"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "cached base refs keep per-branch red state"
  assert_equals "dev" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.details.failed_targets[0].base_ref')" "cached base ref identifies dev branch"
  [ ! -e "$home/gh-calls.log" ] || fail "a cached legacy base ref must not call gh pr view again: $(cat "$home/gh-calls.log")"

  # 4. Legacy record when gh pr view fails -> unknown + stop_dispatch
  home=$(make_home dev_legacy_fail)
  seed_healthy_stubs "$home"
  write_review_ledger "$home" 1442 "$(dev_ledger 1442 passed $((EPOCH_NIGHT_START - 1800)))"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "unresolvable legacy base_ref emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unresolvable legacy base_ref stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "unresolvable legacy base_ref reports dev_health unknown"
  [ ! -e "$home/state/night-pr-base-refs.json" ] || fail "a failed base_ref lookup must not be cached"
  cat > "$home/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ] && [ "${2:-}" = "rate_limit" ]; then
  printf '{"resources":{"core":{"limit":5000,"used":800,"remaining":4200,"reset":1795800000}}}\n'
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf '{"baseRefName":"dev"}\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$home/fakebin/gh"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 300)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "retried legacy base_ref lookup exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "an uncached failed lookup is retried on the next check"

  # 5. Corrupt review ledger fails closed as unknown
  home=$(make_home dev_corrupt)
  seed_healthy_stubs "$home"
  write_review_ledger "$home" 1443 '{not-valid-json'
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "corrupt ledger emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "corrupt ledger stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "corrupt ledger reports dev_health unknown"

  # 6. Producer-to-consumer check: bin/fm-pr-review.sh post-merge records base_ref from forge JSON
  home=$(make_home dev_producer)
  fake_quota_axi "$home/fakebin" 80 70
  cat > "$home/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ] && [ "${2:-}" = "rate_limit" ]; then
  printf '{"resources":{"core":{"limit":5000,"used":800,"remaining":4200,"reset":1795800000}}}\n'
  exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "/repos/twilwa/bbchat/pulls/1500" ]; then
  printf '{"merged":true,"merge_commit_sha":"cccccccccccccccccccccccccccccccccccccccc","head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"base":{"ref":"dev"}}\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$home/fakebin/gh"
  local ev="$home/ev.json" pr_url="https://github.com/twilwa/bbchat/pull/1500" head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  write_review_ledger "$home" 1500 "$(printf '{"schema":"firstmate-pr-review-ledger.v1","task":"task-1500","url":"%s","current_head":"%s","generations":[{"head":"%s","created_epoch":%d,"risk":{"level":"low","reason":"small"},"checkpoints":[],"review_items":[],"attestations":[],"final_disposition":null,"merge_decision":{"decision":"merge","verified_head":"%s","verified_epoch":%d},"post_merge_verifications":[]}]}\n' "$pr_url" "$head" "$head" $((EPOCH_NIGHT_START + 3000)) "$head" $((EPOCH_NIGHT_START + 3600)))"
  printf '{"schema":"firstmate-post-merge-verification.v1","applicability":"not-applicable","head":"%s","reason":"docs only"}\n' "$head" > "$ev"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_REVIEW_NOW="2026-11-27T08:05:00Z" FM_REVIEW_NOW_EPOCH=$((EPOCH_NIGHT_START + 3900)) \
    "$PR_REVIEW" post-merge "$pr_url" "$head" "$ev" >/dev/null || fail "pr-review post-merge must succeed"
  assert_equals "dev" "$(jq -r '.generations[-1].post_merge_verifications[-1].base_ref' "$home/data/pr-review-ledger/github--twilwa--bbchat--1500.json")" "fm-pr-review.sh post-merge records base_ref"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "check after producer post-merge exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "fm-night-check consumes recorded base_ref without gh pr view"
  pass "fm-night-check: dev health tracks per-branch latest post-merge records, resolves legacy records, and consumes fm-pr-review base_ref"
}

write_fake_crew_state() {  # <home> <map_file>
  local home=$1 map=$2
  cat > "$home/fakebin/fake-crew-state.sh" <<EOF
#!/usr/bin/env bash
id=\${1:-}
line=\$(awk -F'\t' -v k="\$id" '\$1 == k { print \$2; exit }' "$map")
if [ -z "\$line" ]; then
  printf 'state: unknown · source: none · unmapped\n'
  exit 0
fi
printf '%s\n' "\$line"
EOF
  chmod +x "$home/fakebin/fake-crew-state.sh"
}

run_night_check_with_crew_state() {  # <home> <now> <args...>
  local home=$1 now=$2
  shift 2
  env \
    -u FM_BACKEND -u FM_HC_BIN -u FM_HC_SOCKET \
    -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SOCKET -u HC_SESSION -u HC_SCOPE \
    FM_CREW_STATE_BIN="$home/fakebin/fake-crew-state.sh" \
    PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" \
    FM_NIGHT_NOW_EPOCH="$now" \
    FM_PROC_ROOT_OVERRIDE="$home/proc" \
    "$CHECK" "$@" </dev/null
}

check_ledger_with_checks() {  # <num> <head> <checks_json>
  local num=$1 head=$2 checks=$3
  printf '{"schema":"firstmate-pr-review-ledger.v1","task":"t-%s","url":"https://github.com/twilwa/bbchat/pull/%s","current_head":"%s","generations":[{"head":"%s","created_epoch":%d,"risk":{"level":"low","reason":"small"},"checkpoints":[{"at":"2026-11-27T07:05:00Z","at_epoch":%d,"head":"%s","pending_reviews":[],"checks":%s,"comment_ids":[]}],"review_items":[],"attestations":[],"final_disposition":null,"merge_decision":null,"post_merge_verifications":[]}]}\n' \
    "$num" "$num" "$head" "$head" $((EPOCH_NIGHT_START + 100)) $((EPOCH_NIGHT_START + 120)) "$head" "$checks"
}

test_check_machine_uses_crew_state_dedups_heads_and_checks_status() {
  local home out rc=0 map h1 h2 h3
  home=$(make_home check_queue)
  seed_healthy_stubs "$home"
  map="$home/crew-state.tsv"
  : > "$map"
  write_fake_crew_state "$home" "$map"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"

  h1=1111111111111111111111111111111111111111
  h2=2222222222222222222222222222222222222222
  h3=3333333333333333333333333333333333333333

  # 1. Working task with pr= and non-CI paused task -> NOT counted
  printf 'kind=ship\npr=https://github.com/twilwa/bbchat/pull/201\npr_head=%s\n' "$h1" > "$home/state/p1.meta"
  printf 'kind=ship\npr=https://github.com/twilwa/bbchat/pull/202\npr_head=%s\n' "$h2" > "$home/state/p2.meta"
  printf 'p1\tstate: working · source: pane · running tests\n' > "$map"
  printf 'p2\tstate: paused · source: status-log · waiting on reviewer reply\n' >> "$map"
  out=$(run_night_check_with_crew_state "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "working/non-CI paused check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "working and non-CI paused tasks do not count"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.conditions.check_machine.details.waiting_count')" "waiting_count is 0"

  # 2. Task in CI admission wait whose current head has RUNNING checks -> EXCLUDED
  #    Task in CI admission wait whose current head has COMPLETED pass/skipping checks -> EXCLUDED
  write_review_ledger "$home" 201 "$(check_ledger_with_checks 201 "$h1" '[{"name":"ci","status":"IN_PROGRESS","conclusion":""}]')"
  write_review_ledger "$home" 202 "$(check_ledger_with_checks 202 "$h2" '[{"name":"lint","status":"COMPLETED","conclusion":"pass"},{"name":"optional","status":"COMPLETED","conclusion":"skipping"}]')"
  printf 'p1\tstate: paused · source: status-log · waiting for CI admission\n' > "$map"
  printf 'p2\tstate: paused · source: status-log · waiting for check-machine slot\n' >> "$map"
  out=$(run_night_check_with_crew_state "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "running/completed checks exclusion exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "PRs with running or COMPLETED pass/skipping checks are excluded"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.conditions.check_machine.details.waiting_count')" "waiting_count stays 0"

  # 3. Two tasks pointing at the SAME PR head waiting for CI admission -> deduplicated to 1 -> continue
  rm -f "$home/data/pr-review-ledger/"*.json
  printf 'kind=ship\npr=https://github.com/twilwa/bbchat/pull/203\npr_head=%s\n' "$h3" > "$home/state/p1.meta"
  printf 'kind=ship\npr=https://github.com/twilwa/bbchat/pull/203\npr_head=%s\n' "$h3" > "$home/state/p2.meta"
  out=$(run_night_check_with_crew_state "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "duplicate PR head check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "duplicate PR head deduplicates to 1"
  assert_equals "1" "$(printf '%s\n' "$out" | jq -r '.conditions.check_machine.details.waiting_count')" "deduplicated waiting_count is 1"

  # 4. Two distinct PR heads in declared CI/check admission wait -> tripped + stop_dispatch (no flag)
  printf 'kind=ship\npr=https://github.com/twilwa/bbchat/pull/204\npr_head=%s\n' "$h2" > "$home/state/p2.meta"
  out=$(run_night_check_with_crew_state "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "2 distinct waiting PR heads check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "2 distinct PR heads waiting for CI admission trip stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.check_machine.status')" "check_machine tripped"
  assert_equals "2" "$(printf '%s\n' "$out" | jq -r '.conditions.check_machine.details.waiting_count')" "waiting_count is 2"
  assert_no_reserve_flag "$home" "the check-machine rule is a level condition and must not set reserve-flag"
  pass "fm-night-check: check-machine rule counts deduplicated CI-admission waits via fm-crew-state and excludes running/passed checks"
}

high_stakes_ledger() {  # <num> <head-char> <created_epoch> [attestations-json]
  local num=$1 c=$2 created=$3 att=${4:-'[]'} head
  head=$(printf "%040d" 0 | tr 0 "$c")
  printf '{"schema":"firstmate-pr-review-ledger.v1","task":"t-%s","url":"https://github.com/twilwa/bbchat/pull/%s","current_head":"%s","generations":[{"head":"%s","created_at":"2026-11-27T07:10:00Z","created_epoch":%d,"risk":{"level":"high","reason":"auth"},"checkpoints":[],"review_items":[],"attestations":%s,"final_disposition":null,"merge_decision":null,"post_merge_verifications":[]}]}\n' \
    "$num" "$num" "$head" "$head" "$created" "$(printf '%s' "$att" | sed "s/HEAD/$head/g")"
}

test_validation_cap_counts_night_created_high_stakes_generations() {
  local home out rc=0
  home=$(make_home val_cap)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"

  # 1. Pre-night high-stakes generation attested during the night -> NOT counted
  write_review_ledger "$home" 299 "$(high_stakes_ledger 299 9 $((EPOCH_NIGHT_START - 3600)) '[{"kind":"no-mistakes","head":"HEAD","evidence":"ok","at":"2026-11-27T07:20:00Z"}]')"
  # 2. Low-stakes generation created during the night -> NOT counted
  write_review_ledger "$home" 300 "$(cat <<EOF
{"schema":"firstmate-pr-review-ledger.v1","task":"t-300","url":"https://github.com/twilwa/bbchat/pull/300","current_head":"1111111111111111111111111111111111111111","generations":[{"head":"1111111111111111111111111111111111111111","created_at":"2026-11-27T07:10:00Z","created_epoch":$((EPOCH_NIGHT_START + 600)),"risk":{"level":"low","reason":"small"},"checkpoints":[],"review_items":[],"attestations":[],"final_disposition":null,"merge_decision":null,"post_merge_verifications":[]}]}
EOF
)"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "pre-night + low-stakes check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "pre-night and low-stakes generations do not count"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.conditions.validation_cap.details.count')" "count is 0"

  # 3. One high-stakes generation created tonight, even before any attestation exists -> count 1 -> continue
  write_review_ledger "$home" 301 "$(high_stakes_ledger 301 2 $((EPOCH_NIGHT_START + 600)))"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "1 night high-stakes generation continues"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "1 high-stakes generation continues"
  assert_equals "1" "$(printf '%s\n' "$out" | jq -r '.conditions.validation_cap.details.count')" "count is 1 without attestations"

  # 4. A second high-stakes generation created tonight, still with zero attestations -> hits cap of 2 -> stop_validation
  write_review_ledger "$home" 302 "$(high_stakes_ledger 302 3 $((EPOCH_NIGHT_START + 1200)))"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "2 night high-stakes generations check exits 0"
  assert_equals "2" "$(printf '%s\n' "$out" | jq -r '.conditions.validation_cap.details.count')" "count is 2"
  assert_equals "stop_validation" "$(printf '%s\n' "$out" | jq -r '.verdict')" "2 high-stakes generations trip stop_validation"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.validation_cap.status')" "validation_cap tripped"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.validation')" "further validations disallowed"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.claude')" "other Claude work stays allowed at the validation cap"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.dispatch')" "dispatch stays allowed at the validation cap"
  pass "fm-night-check: validation cap counts night-created high-stakes generations at PR-ready time and stops at 2"
}

test_host_load_sustained_high_and_unreadable() {
  local home out rc=0
  home=$(make_home high_load)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  printf '26.50 25.00 24.10 4/200 1234\n' > "$home/proc/loadavg"

  # First observation at high load starts the 10-minute timer without tripping yet
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "first high-load check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "transient high load does not trip before 10m"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.host_load.status')" "host_load ok at 0s"

  # 10 minutes later still above 24 -> trips stop_dispatch and disallows validation
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 600)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "sustained high-load check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "load above 24 for 10m trips stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.host_load.status')" "host_load tripped"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.validation')" "sustained high load disallows validation"
  assert_no_reserve_flag "$home" "host load is a level condition and must not set reserve-flag"

  # A high-load start carried in a verdict from long ago does not count as sustained
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 7200)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "sparse high-load check exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.host_load.status')" "a stale high-load start restarts the timer"
  assert_equals "$((EPOCH_IN_WINDOW + 7200))" "$(printf '%s\n' "$out" | jq -r '.conditions.host_load.details.high_load_since_epoch')" "the timer restarts at this sample"

  # Missing /proc/loadavg reports host_load unknown and stops dispatch
  rm -f "$home/proc/loadavg"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 7260)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "missing loadavg emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unreadable loadavg stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.host_load.status')" "host_load unknown"

  # Checks 15 minutes apart, within twice the 10-minute limit, still see sustained load
  home=$(make_home load_sparse)
  seed_healthy_stubs "$home"
  printf '30.00 30.00 30.00 4/200 1234\n' > "$home/proc/loadavg"
  run_night_check "$home" "$EPOCH_IN_WINDOW" check --json >/dev/null 2>&1 || fail "first sparse check must succeed"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 900)) check --json 2>&1) || rc=$?
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.host_load.status')" "two high samples 15m apart trip host load"

  # A load of exactly 24 is not above the threshold, however long it lasts
  home=$(make_home load_at_threshold)
  seed_healthy_stubs "$home"
  printf '24.00 24.00 24.00 4/200 1234\n' > "$home/proc/loadavg"
  run_night_check "$home" "$EPOCH_IN_WINDOW" check --json >/dev/null 2>&1 || fail "threshold check must succeed"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 600)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "threshold check exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.host_load.status')" "load exactly 24 does not trip"
  pass "fm-night-check: sustained host load above 24 for 10m, stale timers, and unreadable loadavg"
}

fake_herdr_core() {  # <dir> <pid> <instance> <uptime_ms> [log_file] [app_term_id]
  local dir=$1 pid=$2 inst=$3 uptime_ms=$4 log_file=${5:-} term_id=${6:-}
  mkdir -p "$dir"
  cat > "$dir/herdr-core" <<EOF
#!/usr/bin/env bash
if [ -n "$log_file" ]; then
  printf 'args=%s|HC_SESSION=%s|HC_SOCKET=%s|HC_TERMINAL_ID=%s\n' "\$*" "\${HC_SESSION-<unset>}" "\${HC_SOCKET-<unset>}" "\${HC_TERMINAL_ID-<unset>}" >> "$log_file"
fi
if [ "\${1:-}" = "--version" ]; then
  printf 'hc 0.1.18\n'
  exit 0
fi
if [ -n "$term_id" ] && [ "\${1:-}" = "get" ] && [ "\${2:-}" = "$term_id" ]; then
  printf '{"id":"%s","labels":{"herdr.space":"fm-app"}}\n' "$term_id"
  exit 0
fi
if [ "\${1:-}" = "server" ] && [ "\${2:-}" = "status" ]; then
  printf '{"core":{"id":"core-1","name":"host"},"finished":0,"holder":{"current":true,"instance":"%s","pid":%d,"terminals":3},"live":3,"pid":%d,"uptime_ms":%s,"version":"0.1.18"}\n' "$inst" "$((pid + 1))" "$pid" "$uptime_ms"
  exit 0
fi
exit 1
EOF
  chmod +x "$dir/herdr-core"
}

supervision_latch_key() {  # <home> -> the engine library's own latch key for this home
  local home=$1
  printf 'claude sonnet\n' > "$home/config/supervision-host"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'lab-session\n' > "$home/state/.lock-session"
  # shellcheck disable=SC2016 # expands in the child shell
  FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$home/proc" bash -c '. "$1/fm-wake-lib.sh" && . "$1/fm-supervision-engine-lib.sh" \
    && fm_supervision_host_config "$2" claude && fm_supervision_host_health_key "$3"' _ \
    "$ROOT/bin" "$home/config" "$home/state"
}

test_supervision_stall_old_wake_latch_and_corrupt_files() {
  local home out rc=0 oldest key
  home=$(make_home stall)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"

  # Fresh wake (10m old) -> continue
  printf '%d\t1\tsignal\tt1\tdone: ok\n' $((EPOCH_IN_WINDOW - 600)) > "$home/state/.wake-queue"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "fresh wake exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "10m wake does not stall"

  # Stale unacknowledged wake (31m old) -> stop_dispatch + durable stall_since_epoch
  oldest=$((EPOCH_IN_WINDOW - 1860))
  printf '%d\t1\tsignal\tt1\tdone: ok\n%d\t2\tcheck\tpr\tdue\n' "$oldest" $((EPOCH_IN_WINDOW - 60)) > "$home/state/.wake-queue"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "stalled wake exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "31m wake trips stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.supervision_stall.status')" "supervision_stall tripped"
  assert_equals "$oldest" "$(jq -r '.stall_since_epoch' "$home/state/night-stop.json")" "durable stop record stores stall_since_epoch"
  [ -f "$home/state/night.reserve" ] || fail "supervision stall sets reserve-flag"

  # The wake is acknowledged later; the stall stays latched with its start time
  : > "$home/state/.wake-queue"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 600)) check --json 2>&1) || rc=$?
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "the stall stays latched after the queue drains"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.merge')" "a latched stall keeps merges stopped"
  assert_equals "$oldest" "$(jq -r '.stall_since_epoch' "$home/state/night-stop.json")" "the stall start time is kept"

  # An engine latch whose retry time has passed still holds until a probe succeeds
  home=$(make_home stall_latch)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  key=$(supervision_latch_key "$home") || fail "could not compute the latch key"
  printf 'key=%s\nerrors=2\ncooldown=300\nretry_after=%d\n' "$key" $((EPOCH_IN_WINDOW - 600)) > "$home/state/.supervision-host-health"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "latched host exits 0"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.supervision_stall.status')" "an unprobed latch past its retry time still trips"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "latched engine trips stop_dispatch"

  # A latch record kept under another engine key is not this engine's latch
  home=$(make_home stall_other_key)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  supervision_latch_key "$home" >/dev/null || fail "could not compute the latch key"
  printf 'key=some-earlier-session|claude|sonnet\nerrors=2\ncooldown=300\nretry_after=%d\n' $((EPOCH_IN_WINDOW + 300)) > "$home/state/.supervision-host-health"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "foreign-key latch exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.supervision_stall.status')" "a leftover latch under another key reads ok"

  # Corrupt .supervision-host-health fails closed as unknown
  home=$(make_home stall_corrupt_health)
  seed_healthy_stubs "$home"
  key=$(supervision_latch_key "$home") || fail "could not compute the latch key"
  printf 'key=%s\nerrors=2\ncooldown=300\nretry_after=not-a-num\n' "$key" > "$home/state/.supervision-host-health"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "corrupt host-health exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "corrupt host-health stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.supervision_stall.status')" "corrupt host-health reports unknown"

  # .supervision-host-health present when an enabled host's engine key cannot be
  # resolved (no state/.lock) -> unknown. The host is enabled explicitly so the
  # case does not depend on which primary harness runs the suite.
  home=$(make_home stall_unresolvable_key)
  seed_healthy_stubs "$home"
  printf 'claude sonnet\n' > "$home/config/supervision-host"
  printf 'key=some-session|claude|sonnet\nerrors=2\ncooldown=300\nretry_after=%d\n' $((EPOCH_IN_WINDOW + 300)) > "$home/state/.supervision-host-health"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "unresolvable engine key exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unresolvable engine key stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.supervision_stall.status')" "unresolvable engine key reports unknown"

  # A leftover health file after the home opted out of the supervision host is not a latch
  home=$(make_home stall_host_disabled)
  seed_healthy_stubs "$home"
  key=$(supervision_latch_key "$home") || fail "could not compute the latch key"
  printf 'key=%s\nerrors=2\ncooldown=300\nretry_after=%d\n' "$key" $((EPOCH_IN_WINDOW + 300)) > "$home/state/.supervision-host-health"
  : > "$home/config/supervision-host-off"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "disabled supervision host exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.supervision_stall.status')" "a disabled supervision host has no engine latch"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "a disabled supervision host does not stop dispatch"

  # Corrupt wake queue fails closed as unknown
  home=$(make_home stall_corrupt)
  seed_healthy_stubs "$home"
  printf 'not-an-epoch\tbad\n' > "$home/state/.wake-queue"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "corrupt wake queue exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "corrupt wake queue stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.supervision_stall.status')" "supervision_stall unknown"
  pass "fm-night-check: supervision stall latches on >30m wake or engine latch, and corrupt/unresolvable files fail closed"
}

test_hc_core_restart_auto_detect_ambient_strip_and_unreadable() {
  local home out rc=0 hc_log sock sock_pid i
  home=$(make_home hc_restart)
  seed_healthy_stubs "$home"
  printf 'hc\n' > "$home/config/backend"
  hc_log="$home/hc-calls.log"
  # Core started well before night start (uptime 86400s = 86400000ms)
  fake_herdr_core "$home/fakebin" 3995 "inst-original" 86400000 "$hc_log"
  env \
    -u FM_BACKEND -u FM_HC_BIN -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SOCKET -u HC_SCOPE \
    FM_HC_SOCKET="$home/expected.sock" HC_SESSION="real-sess" \
    PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_NIGHT_NOW_EPOCH="$EPOCH_NIGHT_START" FM_PROC_ROOT_OVERRIDE="$home/proc" \
    "$CHECK" start >/dev/null 2>&1 || fail "hc start must succeed"
  assert_equals "real-sess" "$(jq -r '.hc_target.session' "$home/state/night-active.json")" "start saves resolved hc session"
  assert_equals "$home/expected.sock" "$(jq -r '.hc_target.socket' "$home/state/night-active.json")" "start saves resolved hc socket"

  # Steady core queried under conflicting ambient HC_SOCKET and HC_SESSION ->
  # check strips ambient HC_SOCKET and uses the saved target
  : > "$hc_log"
  fake_herdr_core "$home/fakebin" 3995 "inst-original" 93600000 "$hc_log"
  out=$(env \
    -u FM_BACKEND -u FM_HC_BIN -u FM_HC_SOCKET -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE \
    HC_SOCKET="/bogus/ambient.sock" HC_SESSION="wrong-sess" \
    PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_NIGHT_NOW_EPOCH="$EPOCH_IN_WINDOW" FM_PROC_ROOT_OVERRIDE="$home/proc" \
    "$CHECK" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "steady hc core exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "steady hc core continues"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "hc_core ok"
  assert_contains "$(cat "$hc_log")" "HC_SESSION=real-sess|HC_SOCKET=$home/expected.sock|" "check uses saved hc target and ignores conflicting ambient HC_SOCKET/HC_SESSION"

  # Same pid, holder instance, and core id with an uptime that drifted behind wall time
  # (e.g. host sleep) is not a restart when a baseline exists
  fake_herdr_core "$home/fakebin" 3995 "inst-original" 12000 "$hc_log"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "drifted hc uptime exits 0"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "uptime drift with unchanged identity is not a restart"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "uptime drift with unchanged identity continues"

  # Core restarted (new pid + new holder instance + short uptime) -> end_night
  fake_herdr_core "$home/fakebin" 8812 "inst-restarted" 12000 "$hc_log"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "restarted hc core exits 0"
  assert_equals "end_night" "$(printf '%s\n' "$out" | jq -r '.verdict')" "hc core restart ends the night"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "hc_core tripped"
  assert_equals "true" "$(jq -r '.core_restarted' "$home/state/night-stop.json")" "stop record flags core_restarted=true"
  [ -f "$home/state/night.reserve" ] || fail "hc core restart sets reserve-flag"

  # Auto-detected hc via app-terminal (no config/backend, no FM_BACKEND), stubbed unix socket only
  home=$(make_home hc_auto_detect)
  seed_healthy_stubs "$home"
  sock="$home/app.sock"
  hc_log="$home/hc-auto.log"
  fake_herdr_core "$home/fakebin" 5100 "inst-auto" 86400000 "$hc_log" "term-auto-1"
  python3 -c '
import signal, socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    time.sleep(1)
' "$sock" &
  sock_pid=$!
  i=0
  while [ ! -S "$sock" ] && [ "$i" -lt 40 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if [ ! -S "$sock" ]; then
    kill "$sock_pid" 2>/dev/null || true
    wait "$sock_pid" 2>/dev/null || true
    fail "stub unix socket did not appear"
  fi
  rc=0
  env \
    -u FM_BACKEND -u FM_HC_BIN -u HC_SOCKET -u HC_SCOPE \
    HC_TERMINAL_ID="term-auto-1" HC_TERMINAL_SOCKET="$sock" FM_HC_SOCKET="$sock" HC_SESSION="auto-sess" \
    PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_NIGHT_NOW_EPOCH="$EPOCH_NIGHT_START" FM_PROC_ROOT_OVERRIDE="$home/proc" \
    "$CHECK" start >/dev/null 2>&1 || rc=$?
  # Stop the stub socket listener before assertions so no listener can ever leak on failure
  kill "$sock_pid" 2>/dev/null || true
  wait "$sock_pid" 2>/dev/null || true
  rm -f "$sock"
  expect_code 0 "$rc" "auto-detected app-terminal hc start must succeed"
  assert_equals "auto-sess" "$(jq -r '.hc_target.session' "$home/state/night-active.json")" "auto-detected hc saves session at start"
  assert_equals "$sock" "$(jq -r '.hc_target.socket' "$home/state/night-active.json")" "auto-detected hc saves socket at start"
  assert_equals "5100" "$(jq -r '.hc_baseline.pid' "$home/state/night-active.json")" "auto-detected hc records baseline pid"

  # After start, check monitors the saved auto-detected hc target even without HC_TERMINAL_ID
  fake_herdr_core "$home/fakebin" 9900 "inst-auto-restarted" 5000 "$hc_log" "term-auto-1"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "auto-detected hc restart check exits 0"
  assert_equals "end_night" "$(printf '%s\n' "$out" | jq -r '.verdict')" "auto-detected hc core restart ends night"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "auto-detected hc_core tripped"

  # Unresolvable config/backend -> unknown + stop_dispatch
  home=$(make_home hc_unresolvable)
  seed_healthy_stubs "$home"
  printf 'bogus-backend\n' > "$home/config/backend"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "unresolvable backend check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unresolvable backend stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "unresolvable backend reports unknown"

  # Live app-terminal socket with unusable herdr-core toolchain -> unknown + stop_dispatch
  home=$(make_home hc_app_unusable)
  seed_healthy_stubs "$home"
  sock="$home/unusable.sock"
  cat > "$home/fakebin/herdr-core" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$home/fakebin/herdr-core"
  python3 -c '
import signal, socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    time.sleep(1)
' "$sock" &
  sock_pid=$!
  i=0
  while [ ! -S "$sock" ] && [ "$i" -lt 40 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  rc=0
  out=$(env \
    -u FM_BACKEND -u FM_HC_SOCKET -u HC_SOCKET -u HC_SCOPE \
    FM_HC_BIN="$home/fakebin/herdr-core" \
    HC_TERMINAL_ID="term-unusable" HC_TERMINAL_SOCKET="$sock" \
    PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_NIGHT_NOW_EPOCH="$EPOCH_IN_WINDOW" FM_PROC_ROOT_OVERRIDE="$home/proc" \
    "$CHECK" check --json 2>&1) || rc=$?
  kill "$sock_pid" 2>/dev/null || true
  wait "$sock_pid" 2>/dev/null || true
  rm -f "$sock"
  expect_code 0 "$rc" "unusable app-terminal check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unusable app-terminal stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "unusable app-terminal reports unknown"

  # Unreadable hc core status -> unknown + stop_dispatch, without latching
  home=$(make_home hc_unreadable)
  seed_healthy_stubs "$home"
  printf 'hc\n' > "$home/config/backend"
  cat > "$home/fakebin/herdr-core" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$home/fakebin/herdr-core"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "unreadable hc core exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unreadable hc core stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "hc_core reports unknown"
  pass "fm-night-check: hc core restart, auto-detected app-terminal target, ambient HC_SOCKET strip, and unreadable/unresolvable fail-closed"
}

test_hc_guard_blocks_install_only() {
  local home out rc=0 lab_dir sock_dir
  home=$(make_home hc_guard)
  seed_healthy_stubs "$home"

  # Before night start, hc-guard allows operations
  FM_HOME="$home" "$CHECK" hc-guard >/dev/null 2>&1 || fail "hc-guard must exit 0 before night starts"

  # Start night -> hc-guard refuses
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  out=$(FM_HOME="$home" "$CHECK" hc-guard 2>&1) || rc=$?
  expect_code 1 "$rc" "hc-guard must exit 1 while night is active"
  assert_contains "$out" "overnight run is active" "hc-guard refusal states reason"

  # bin/fm-install-hc.sh refuses before any download while night is active
  local curl_log="$home/curl.log"
  cat > "$home/fakebin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$curl_log"
exit 99
EOF
  chmod +x "$home/fakebin/curl"
  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-install-hc.sh" "$home/dest-hc" 2>&1) || rc=$?
  expect_code 1 "$rc" "fm-install-hc.sh must refuse while night is active"
  assert_contains "$out" "overnight run is active" "fm-install-hc.sh prints night guard reason"
  [ ! -e "$curl_log" ] || fail "fm-install-hc.sh must refuse before invoking curl"
  [ ! -e "$home/dest-hc/herdr-core" ] || fail "fm-install-hc.sh must not install binary while guarded"

  # Isolated lab sessions never touch the real core, so their stop and teardown
  # paths reach their own checks instead of the night guard
  lab_dir="$home/hclab"
  sock_dir="$home/hcsock"
  mkdir -p "$lab_dir" "$sock_dir"
  chmod 700 "$lab_dir" "$sock_dir"
  rc=0
  out=$(FM_HOME="$home" FM_HC_LAB_DIR="$lab_dir" FM_HC_LAB_SOCK_DIR="$sock_dir" \
    "$ROOT/bin/fm-hc-lab.sh" stop fm-hclab-test1 2>&1) || rc=$?
  assert_contains "$out" "missing fleet-state tripwire" "fm-hc-lab.sh stop reaches its own tripwire check during a night"
  assert_not_contains "$out" "overnight run is active" "fm-hc-lab.sh stop is not night-guarded"
  rc=0
  out=$(FM_HOME="$home" FM_HC_LAB_DIR="$lab_dir" FM_HC_LAB_SOCK_DIR="$sock_dir" \
    "$ROOT/bin/fm-hc-lab.sh" teardown fm-hclab-test1 2>&1) || rc=$?
  assert_contains "$out" "missing fleet-state tripwire" "fm-hc-lab.sh teardown reaches its own tripwire check during a night"
  assert_not_contains "$out" "overnight run is active" "fm-hc-lab.sh teardown is not night-guarded"
  rc=0
  out=$(FM_HOME="$home" FM_HC_LAB_DIR="$lab_dir" FM_HC_LAB_SOCK_DIR="$sock_dir" \
    "$ROOT/bin/fm-hc-ci-cleanup.sh" teardown "$home/missing-snap.txt" 2>&1) || rc=$?
  assert_contains "$out" "snapshot file not found" "fm-hc-ci-cleanup.sh teardown reaches its own checks during a night"
  assert_not_contains "$out" "overnight run is active" "fm-hc-ci-cleanup.sh teardown is not night-guarded"

  # Corrupt night-active.json fails closed
  printf '{corrupt\n' > "$home/state/night-active.json"
  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-install-hc.sh" "$home/dest-hc" 2>&1) || rc=$?
  expect_code 1 "$rc" "corrupt night-active.json still refuses fm-install-hc.sh"
  [ ! -e "$curl_log" ] || fail "corrupt night-active.json must refuse before invoking curl"

  # After end, hc-guard exits 0 again
  run_night_check "$home" "$EPOCH_AFTER_END" end >/dev/null 2>&1 || fail "end must succeed"
  FM_HOME="$home" "$CHECK" hc-guard >/dev/null 2>&1 || fail "hc-guard must exit 0 after night ends"
  pass "fm-night-check: hc guard blocks fm-install-hc.sh while night is active and leaves lab paths alone"
}

test_stop_condition_never_kills_or_tears_down_workers() {
  local home out rc=0 hc_log
  home=$(make_home non_destructive)
  seed_healthy_stubs "$home"
  printf 'hc\n' > "$home/config/backend"
  hc_log="$home/hc-calls.log"
  fake_herdr_core "$home/fakebin" 4000 "inst-1" 90000000 "$hc_log"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"

  # Seed an active worker record, then trigger end_night via window end
  printf 'kind=ship\nbackend=hc\nwindow=default:t1\n' > "$home/state/w1.meta"
  printf 'working [at=%d]: building\n' $((EPOCH_NIGHT_START + 100)) > "$home/state/w1.status"
  : > "$hc_log"
  out=$(run_night_check "$home" "$EPOCH_AFTER_END" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "end_night check exits 0"
  assert_equals "end_night" "$(printf '%s\n' "$out" | jq -r '.verdict')" "window end yields end_night"
  [ -f "$home/state/w1.meta" ] || fail "night check must never remove worker meta"
  [ -f "$home/state/w1.status" ] || fail "night check must never remove worker status"
  assert_no_grep '(kill|rm|stop|send)' "$hc_log" "night check must never invoke hc kill/rm/stop/send"
  pass "fm-night-check: stop conditions never kill, interrupt, or tear down workers"
}

fm_test_run \
  test_help_and_usage \
  test_healthy_night_verdict_and_machine_readable_output \
  test_two_hour_default_gated_on_active_night_and_transitions \
  test_night_window_last_dispatch_cutoff_is_level_and_sets_no_flag \
  test_night_window_ended_ends_night_without_flag \
  test_check_outside_active_night_sets_nothing \
  test_malformed_config_dangling_symlink_and_bad_timezone_fail_closed \
  test_claude_quota_floors_boundaries_and_config_bounds \
  test_claude_quota_partial_stale_and_unreadable_fail_closed \
  test_github_api_below_floor_recovers_and_unreadable \
  test_failure_streak_latches_until_end \
  test_failure_streak_excludes_scouts_secondmates_and_pre_night_tasks \
  test_corrupt_stop_record_stops_dispatch_without_latching_or_flag \
  test_end_clears_recorded_reserve_flag_even_after_config_change \
  test_foreign_reserve_flag_left_untouched \
  test_missing_reserve_flag_config_warns \
  test_dev_health_per_branch_recovery_legacy_fallback_and_producer \
  test_check_machine_uses_crew_state_dedups_heads_and_checks_status \
  test_validation_cap_counts_night_created_high_stakes_generations \
  test_host_load_sustained_high_and_unreadable \
  test_supervision_stall_old_wake_latch_and_corrupt_files \
  test_hc_core_restart_auto_detect_ambient_strip_and_unreadable \
  test_hc_guard_blocks_install_only \
  test_stop_condition_never_kills_or_tears_down_workers
