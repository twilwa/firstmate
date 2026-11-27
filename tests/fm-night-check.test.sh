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
  printf '4\nreserve-flag %s/state/night.reserve night stop\n' "$home" > "$home/config/lane-capacity"
  printf '%s\n' "$home"
}

fake_quota_axi() {
  local dir=$1 five_rem=$2 week_rem=$3 five_used week_used
  five_used=$((100 - five_rem))
  week_used=$((100 - week_rem))
  mkdir -p "$dir"
  cat > "$dir/quota-axi" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
{"generatedAt":"2026-11-27T09:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"max","account":{"accountId":"acct","email":"a@example.com","organization":"org","identityStatus":"verified"},"windows":[{"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":$five_used,"percentRemaining":$five_rem},{"id":"seven_day","label":"week","kind":"weekly","percentUsed":$week_used,"percentRemaining":$week_rem}],"attempts":[],"state":{"status":"fresh","stale":false,"refreshedAt":"2026-11-27T09:00:00Z","sourcesTried":[]},"quotaSemantics":{"status":"known","description":"d","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":$five_rem,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset"}}]}}]}
JSON
EOF
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
  PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" \
    FM_NIGHT_NOW_EPOCH="$now" \
    FM_PROC_ROOT_OVERRIDE="$home/proc" \
    "$CHECK" "$@" </dev/null
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
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.two_hour_default')" "two-hour default allowed"
  assert_equals "0" "$(printf '%s\n' "$out" | jq -r '.tripped | length')" "no tripped conditions"
  [ ! -e "$home/state/night-stop.json" ] || fail "healthy check must not write night-stop.json"
  [ ! -e "$home/state/night.reserve" ] || fail "healthy check must not set reserve-flag"

  # P2 and P3 consume the latest stored verdict without re-polling external sources
  stored=$(FM_HOME="$home" "$CHECK" verdict --json 2>&1) || fail "verdict --json must read stored verdict"
  assert_equals "continue" "$(printf '%s\n' "$stored" | jq -r '.verdict')" "stored verdict matches latest check"
  assert_equals "true" "$(printf '%s\n' "$stored" | jq -r '.allow.two_hour_default')" "stored verdict exposes two_hour_default"
  pass "fm-night-check: healthy night verdict and stored machine-readable consumption"
}

test_night_window_last_dispatch_cutoff_stops_dispatch_and_sets_reserve_flag() {
  local home out rc=0 admit_rc=0 admit_out
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
  [ -f "$home/state/night-stop.json" ] || fail "stop condition must write durable state/night-stop.json"
  assert_equals "fm-night-stop.v1" "$(jq -r '.schema' "$home/state/night-stop.json")" "stop record schema"
  [ -f "$home/state/night.reserve" ] || fail "stop_dispatch must set reserve-flag from config/lane-capacity"

  # Verify bin/fm-capacity.sh --admit actually refuses new spawns via that reserve-flag
  admit_out=$(FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$home/proc" "$CAPACITY" --admit 2>&1) || admit_rc=$?
  expect_code 75 "$admit_rc" "fm-capacity.sh --admit must defer (75) once reserve-flag is set"
  assert_contains "$admit_out" "night stop" "fm-capacity refusal names the reserve-flag label"
  pass "fm-night-check: last-dispatch cutoff stops dispatch, writes stop record, and sets reserve-flag"
}

test_night_window_ended_ends_night() {
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
  [ -f "$home/state/night-stop.json" ] || fail "end_night writes durable stop record"
  [ -f "$home/state/night.reserve" ] || fail "end_night sets reserve-flag"
  pass "fm-night-check: window end produces end_night verdict"
}

test_malformed_night_config_fails_closed_as_unknown() {
  local home out rc=0
  home=$(make_home bad_config)
  seed_healthy_stubs "$home"
  printf 'window-start not-a-time\n' > "$home/config/night-check"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "malformed config still emits fail-closed verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "malformed config stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.night_window.status')" "malformed config reports night_window unknown"
  [ -f "$home/state/night.reserve" ] || fail "unknown condition must set reserve-flag"
  pass "fm-night-check: malformed config fails closed as unknown and stops dispatch"
}

test_claude_quota_below_25_stops_claude_only() {
  local home out rc=0 admit_rc=0
  home=$(make_home quota_20)
  fake_quota_axi "$home/fakebin" 80 20
  fake_gh_rate_limit "$home/fakebin" 4200
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "quota <25% check must exit 0"
  assert_equals "stop_claude" "$(printf '%s\n' "$out" | jq -r '.verdict')" "weekly 20% trips stop_claude"
  assert_equals "true" "$(printf '%s\n' "$out" | jq -r '.allow.dispatch')" "non-Claude dispatch remains allowed"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.claude')" "Claude work disallowed"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.validation')" "Claude validation disallowed"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.claude_quota.status')" "claude_quota tripped"
  [ -f "$home/state/night-stop.json" ] || fail "stop_claude still records durable night-stop.json"
  [ ! -e "$home/state/night.reserve" ] || fail "stop_claude must NOT set reserve-flag so non-Claude builders can dispatch"
  FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$home/proc" "$CAPACITY" --admit >/dev/null 2>&1 || admit_rc=$?
  expect_code 0 "$admit_rc" "fm-capacity.sh --admit still admits non-Claude work on stop_claude"
  pass "fm-night-check: Claude quota below 25% stops Claude work only"
}

test_claude_quota_below_12_stops_all_dispatch() {
  local home out rc=0
  home=$(make_home quota_10)
  fake_quota_axi "$home/fakebin" 10 60
  fake_gh_rate_limit "$home/fakebin" 4200
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "quota <12% check must exit 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "5h 10% trips stop_dispatch"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.dispatch')" "all dispatch disallowed"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.claude')" "Claude disallowed"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.claude_quota.status')" "claude_quota tripped"
  [ -f "$home/state/night.reserve" ] || fail "quota <12% must set reserve-flag"
  pass "fm-night-check: Claude quota below 12% stops all dispatch and sets reserve-flag"
}

test_unreadable_quota_source_stops_dispatch() {
  local home out rc=0
  home=$(make_home quota_broken)
  fake_gh_rate_limit "$home/fakebin" 4200
  cat > "$home/fakebin/quota-axi" <<'EOF'
#!/usr/bin/env bash
printf 'not-valid-json\n'
exit 0
EOF
  chmod +x "$home/fakebin/quota-axi"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "unreadable quota-axi still emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unreadable quota-axi stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.claude_quota.status')" "claude_quota reports unknown"
  [ -f "$home/state/night.reserve" ] || fail "unreadable quota-axi must set reserve-flag"
  pass "fm-night-check: unreadable quota-axi reports unknown and stops dispatch"
}

test_github_api_below_floor_and_unreadable() {
  local home out rc=0
  home=$(make_home gh_low)
  fake_quota_axi "$home/fakebin" 80 70
  fake_gh_rate_limit "$home/fakebin" 999
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "low gh api check must exit 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "gh remaining 999 trips stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.github_api.status')" "github_api tripped"
  [ -f "$home/state/night.reserve" ] || fail "low gh api must set reserve-flag"

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
  [ -f "$home/state/night.reserve" ] || fail "unreadable gh must set reserve-flag"
  pass "fm-night-check: GitHub API floor and unreadable source"
}

write_review_ledger() {  # <home> <pr-num> <json>
  local home=$1 num=$2 json=$3
  mkdir -p "$home/data/pr-review-ledger"
  printf '%s\n' "$json" > "$home/data/pr-review-ledger/github--twilwa--bbchat--${num}.json"
}

test_failure_streak_three_consecutive_stops_dispatch() {
  local home out rc=0
  home=$(make_home streak_trip)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  printf 'done [at=%d]: PR https://github.com/twilwa/bbchat/pull/1\n' $((EPOCH_NIGHT_START + 100)) > "$home/state/t0.status"
  printf 'failed [at=%d]: build broke\n' $((EPOCH_NIGHT_START + 200)) > "$home/state/t1.status"
  mkdir -p "$home/data/t2"
  printf 'failed [at=%d]: test timeout\n' $((EPOCH_NIGHT_START + 300)) > "$home/data/t2/status.log"
  printf 'failed [at=%d]: lint error\n' $((EPOCH_NIGHT_START + 400)) > "$home/state/t3.status"

  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "failure streak check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "3 consecutive failures trip stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.failure_streak.status')" "failure_streak tripped"
  assert_equals "3" "$(printf '%s\n' "$out" | jq -r '.conditions.failure_streak.details.streak')" "streak count is 3"
  [ -f "$home/state/night.reserve" ] || fail "failure streak must set reserve-flag"

  # A newer done ticket resets the trailing failure streak
  printf 'done [at=%d]: PR https://github.com/twilwa/bbchat/pull/2\n' $((EPOCH_NIGHT_START + 500)) > "$home/state/t4.status"
  rm -f "$home/state/night.reserve" "$home/state/night-stop.json"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "reset streak check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "newer done resets failure streak"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.failure_streak.status')" "failure_streak ok"
  pass "fm-night-check: failure streak trips at 3 consecutive failures and resets on done"
}

test_dev_health_failed_post_merge_and_corrupt_ledger() {
  local home out rc=0
  home=$(make_home dev_red)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"
  write_review_ledger "$home" 1442 "$(cat <<EOF
{"schema":"firstmate-pr-review-ledger.v1","task":"t-1442","url":"https://github.com/twilwa/bbchat/pull/1442","current_head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generations":[{"head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","created_at":"2026-11-27T07:10:00Z","created_epoch":$((EPOCH_NIGHT_START + 600)),"risk":{"level":"low","reason":"small"},"checkpoints":[],"review_items":[],"attestations":[],"final_disposition":null,"merge_decision":{"decision":"merge","verified_head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","verified_epoch":$((EPOCH_NIGHT_START + 900))},"post_merge_verifications":[{"applicability":"browser","outcome":"failed","ready_for_qa":"blocked","recorded_epoch":$((EPOCH_NIGHT_START + 1200)),"recorded_at":"2026-11-27T07:20:00Z"}]}]}
EOF
)"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "dev health check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "failed post-merge trips stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "dev_health tripped"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.merge')" "failed post-merge stops merges"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.two_hour_default')" "failed post-merge disallows two-hour default"
  [ -f "$home/state/night.reserve" ] || fail "failed post-merge sets reserve-flag"

  # Corrupt review ledger fails closed as unknown
  home=$(make_home dev_corrupt)
  seed_healthy_stubs "$home"
  write_review_ledger "$home" 1443 '{not-valid-json'
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "corrupt ledger emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "corrupt ledger stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.dev_health.status')" "corrupt ledger reports dev_health unknown"
  [ -f "$home/state/night.reserve" ] || fail "corrupt ledger sets reserve-flag"
  pass "fm-night-check: dev health failed post-merge check and corrupt review ledger"
}

test_check_machine_two_waiting_prs_stops_dispatch() {
  local home out rc=0
  home=$(make_home check_queue)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"

  # One finished PR waiting for a slot + one PR already checks-green -> only 1 waiting -> continue
  printf 'kind=ship\npr=https://github.com/twilwa/bbchat/pull/201\n' > "$home/state/p1.meta"
  printf 'done [at=%d]: PR https://github.com/twilwa/bbchat/pull/201\n' $((EPOCH_NIGHT_START + 100)) > "$home/state/p1.status"
  printf 'kind=ship\npr=https://github.com/twilwa/bbchat/pull/202\n' > "$home/state/p2.meta"
  printf 'done [at=%d]: PR https://github.com/twilwa/bbchat/pull/202 checks green\n' $((EPOCH_NIGHT_START + 120)) > "$home/state/p2.status"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "1 waiting PR check exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "only 1 waiting PR continues"
  assert_equals "1" "$(printf '%s\n' "$out" | jq -r '.conditions.check_machine.details.waiting_count')" "waiting_count is 1"

  # Second finished PR waiting for a slot -> 2 waiting -> stop_dispatch
  printf 'kind=ship\npr=https://github.com/twilwa/bbchat/pull/203\n' > "$home/state/p3.meta"
  printf 'done [at=%d]: PR https://github.com/twilwa/bbchat/pull/203\n' $((EPOCH_NIGHT_START + 150)) > "$home/state/p3.status"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "2 waiting PRs check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "2 waiting PRs trip stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.check_machine.status')" "check_machine tripped"
  assert_equals "2" "$(printf '%s\n' "$out" | jq -r '.conditions.check_machine.details.waiting_count')" "waiting_count is 2"
  [ -f "$home/state/night.reserve" ] || fail "check_machine trip sets reserve-flag"
  pass "fm-night-check: check-machine rule stops dispatch at >=2 finished PRs waiting for a slot"
}

test_validation_cap_two_high_stakes_runs() {
  local home out rc=0
  home=$(make_home val_cap)
  seed_healthy_stubs "$home"
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "start must succeed"

  # Low-stakes attestation does not count toward high-stakes validation cap
  write_review_ledger "$home" 300 "$(cat <<EOF
{"schema":"firstmate-pr-review-ledger.v1","task":"t-300","url":"https://github.com/twilwa/bbchat/pull/300","current_head":"1111111111111111111111111111111111111111","generations":[{"head":"1111111111111111111111111111111111111111","created_at":"2026-11-27T07:10:00Z","created_epoch":$((EPOCH_NIGHT_START + 600)),"risk":{"level":"low","reason":"small"},"checkpoints":[],"review_items":[],"attestations":[{"kind":"no-mistakes","head":"1111111111111111111111111111111111111111","model":"claude-opus-5-5","evidence":"ok","at":"2026-11-27T07:15:00Z"}],"final_disposition":null,"merge_decision":null,"post_merge_verifications":[]}]}
EOF
)"
  # High-stakes attestation #1 in review ledger
  write_review_ledger "$home" 301 "$(cat <<EOF
{"schema":"firstmate-pr-review-ledger.v1","task":"t-301","url":"https://github.com/twilwa/bbchat/pull/301","current_head":"2222222222222222222222222222222222222222","generations":[{"head":"2222222222222222222222222222222222222222","created_at":"2026-11-27T07:10:00Z","created_epoch":$((EPOCH_NIGHT_START + 600)),"risk":{"level":"high","reason":"auth"},"checkpoints":[],"review_items":[],"attestations":[{"kind":"no-mistakes","head":"2222222222222222222222222222222222222222","model":"claude-opus-5-5","evidence":"ok","at":"2026-11-27T07:20:00Z"}],"final_disposition":null,"merge_decision":null,"post_merge_verifications":[]}]}
EOF
)"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "1 high-stakes validation continues"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "1 validation continues"
  assert_equals "1" "$(printf '%s\n' "$out" | jq -r '.conditions.validation_cap.details.count')" "high-stakes count is 1"

  # High-stakes validation #2 recorded via record-validation -> hits cap of 2
  run_night_check "$home" "$EPOCH_IN_WINDOW" record-validation "val-scout-302" >/dev/null 2>&1 || fail "record-validation must succeed"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "2 high-stakes validations check exits 0"
  assert_equals "stop_claude" "$(printf '%s\n' "$out" | jq -r '.verdict')" "2 high-stakes validations trip stop_claude"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.validation_cap.status')" "validation_cap tripped"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.validation')" "further validations disallowed"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.claude')" "new Claude work disallowed"
  [ -f "$home/state/night-stop.json" ] || fail "validation cap writes durable night-stop.json"
  pass "fm-night-check: validation cap stops at 2 high-stakes validation runs per night"
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

  # 10 minutes later still >= 24 -> trips stop_dispatch and disallows validation
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 600)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "sustained high-load check exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "load >=24 for 10m trips stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.host_load.status')" "host_load tripped"
  assert_equals "false" "$(printf '%s\n' "$out" | jq -r '.allow.validation')" "sustained high load disallows validation"
  [ -f "$home/state/night.reserve" ] || fail "sustained high load sets reserve-flag"

  # Missing /proc/loadavg reports host_load unknown and stops dispatch
  rm -f "$home/proc/loadavg" "$home/state/night.reserve"
  out=$(run_night_check "$home" $((EPOCH_IN_WINDOW + 660)) check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "missing loadavg emits verdict"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unreadable loadavg stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.host_load.status')" "host_load unknown"
  pass "fm-night-check: sustained high host load (24 for 10m) and unreadable loadavg"
}

fake_herdr_core() {  # <dir> <pid> <instance> <uptime_ms>
  local dir=$1 pid=$2 inst=$3 uptime_ms=$4
  mkdir -p "$dir"
  cat > "$dir/herdr-core" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "server" ] && [ "\${2:-}" = "status" ]; then
  printf '{"core":{"id":"core-1","name":"host"},"finished":0,"holder":{"current":true,"instance":"%s","pid":%d,"terminals":3},"live":3,"pid":%d,"uptime_ms":%s,"version":"0.1.18"}\n' "$inst" "$((pid + 1))" "$pid" "$uptime_ms"
  exit 0
fi
exit 1
EOF
  chmod +x "$dir/herdr-core"
}

test_supervision_stall_old_wake_latch_and_corrupt_queue() {
  local home out rc=0 oldest
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

  # Latched supervision-host trips supervision_stall even with empty wake queue
  : > "$home/state/.wake-queue"
  rm -f "$home/state/night.reserve" "$home/state/night-stop.json"
  printf 'key=k1\nerrors=2\ncooldown=600\nretry_after=%d\n' $((EPOCH_IN_WINDOW + 300)) > "$home/state/.supervision-host-health"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "latched host exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "latched engine trips stop_dispatch"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.supervision_stall.status')" "supervision_stall tripped on latch"

  # Corrupt wake queue fails closed as unknown
  rm -f "$home/state/.supervision-host-health" "$home/state/night.reserve"
  printf 'not-an-epoch\tbad\n' > "$home/state/.wake-queue"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "corrupt wake queue exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "corrupt wake queue stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.supervision_stall.status')" "supervision_stall unknown"
  pass "fm-night-check: supervision stall detects >30m wake, engine latch, and corrupt queue"
}

test_hc_core_restart_ends_night_and_unreadable_stops_dispatch() {
  local home out rc=0
  home=$(make_home hc_restart)
  seed_healthy_stubs "$home"
  printf 'hc\n' > "$home/config/backend"
  # Core started well before night start (uptime 86400s = 86400000ms)
  fake_herdr_core "$home/fakebin" 3995 "inst-original" 86400000
  run_night_check "$home" "$EPOCH_NIGHT_START" start >/dev/null 2>&1 || fail "hc start must succeed"

  # Steady core -> continue
  fake_herdr_core "$home/fakebin" 3995 "inst-original" 93600000
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "steady hc core exits 0"
  assert_equals "continue" "$(printf '%s\n' "$out" | jq -r '.verdict')" "steady hc core continues"
  assert_equals "ok" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "hc_core ok"

  # Core restarted (new pid + new holder instance + short uptime) -> end_night
  fake_herdr_core "$home/fakebin" 8812 "inst-restarted" 12000
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "restarted hc core exits 0"
  assert_equals "end_night" "$(printf '%s\n' "$out" | jq -r '.verdict')" "hc core restart ends the night"
  assert_equals "tripped" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "hc_core tripped"
  assert_equals "true" "$(jq -r '.core_restarted' "$home/state/night-stop.json")" "stop record flags core_restarted=true"
  [ -f "$home/state/night.reserve" ] || fail "hc core restart sets reserve-flag"

  # Unreadable hc core status -> unknown + stop_dispatch
  rm -f "$home/state/night.reserve" "$home/state/night-stop.json"
  cat > "$home/fakebin/herdr-core" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$home/fakebin/herdr-core"
  out=$(run_night_check "$home" "$EPOCH_IN_WINDOW" check --json 2>&1) || rc=$?
  expect_code 0 "$rc" "unreadable hc core exits 0"
  assert_equals "stop_dispatch" "$(printf '%s\n' "$out" | jq -r '.verdict')" "unreadable hc core stops dispatch"
  assert_equals "unknown" "$(printf '%s\n' "$out" | jq -r '.conditions.hc_core.status')" "hc_core reports unknown"
  [ -f "$home/state/night.reserve" ] || fail "unreadable hc core sets reserve-flag"
  pass "fm-night-check: hc core restart ends night and unreadable core stops dispatch"
}

test_hc_guard_blocks_install_and_core_stop_paths() {
  local home out rc=0 lab_dir sock_dir snap
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

  # bin/fm-hc-lab.sh stop and teardown refuse while night is active
  lab_dir="$home/hclab"
  sock_dir="$home/hcsock"
  mkdir -p "$lab_dir/fm-hclab-test1" "$sock_dir"
  chmod 700 "$lab_dir" "$lab_dir/fm-hclab-test1" "$sock_dir"
  : > "$lab_dir/fm-hclab-test1/fleet-state.txt"
  : > "$lab_dir/fm-hclab-test1/fleet-roots.txt"
  rc=0
  out=$(FM_HOME="$home" FM_HC_LAB_DIR="$lab_dir" FM_HC_LAB_SOCK_DIR="$sock_dir" \
    "$ROOT/bin/fm-hc-lab.sh" stop fm-hclab-test1 2>&1) || rc=$?
  expect_code 1 "$rc" "fm-hc-lab.sh stop must refuse while night is active"
  assert_contains "$out" "overnight run is active" "fm-hc-lab.sh stop prints night guard reason"

  rc=0
  out=$(FM_HOME="$home" FM_HC_LAB_DIR="$lab_dir" FM_HC_LAB_SOCK_DIR="$sock_dir" \
    "$ROOT/bin/fm-hc-lab.sh" teardown fm-hclab-test1 2>&1) || rc=$?
  expect_code 1 "$rc" "fm-hc-lab.sh teardown must refuse while night is active"
  assert_contains "$out" "overnight run is active" "fm-hc-lab.sh teardown prints night guard reason"

  # bin/fm-hc-ci-cleanup.sh teardown refuses while night is active
  snap="$home/ci-snap.txt"
  : > "$snap"
  rc=0
  out=$(FM_HOME="$home" FM_HC_LAB_DIR="$lab_dir" FM_HC_LAB_SOCK_DIR="$sock_dir" \
    "$ROOT/bin/fm-hc-ci-cleanup.sh" teardown "$snap" 2>&1) || rc=$?
  expect_code 1 "$rc" "fm-hc-ci-cleanup.sh teardown must refuse while night is active"
  assert_contains "$out" "overnight run is active" "fm-hc-ci-cleanup.sh teardown prints night guard reason"

  # Corrupt night-active.json fails closed
  printf '{corrupt\n' > "$home/state/night-active.json"
  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-install-hc.sh" "$home/dest-hc" 2>&1) || rc=$?
  expect_code 1 "$rc" "corrupt night-active.json still refuses fm-install-hc.sh"
  [ ! -e "$curl_log" ] || fail "corrupt night-active.json must refuse before invoking curl"

  # After end, hc-guard exits 0 again
  run_night_check "$home" "$EPOCH_AFTER_END" end >/dev/null 2>&1 || fail "end must succeed"
  FM_HOME="$home" "$CHECK" hc-guard >/dev/null 2>&1 || fail "hc-guard must exit 0 after night ends"
  pass "fm-night-check: hc guard blocks fm-install-hc.sh and core stop paths while night is active"
}

test_stop_condition_never_kills_or_tears_down_workers() {
  local home out rc=0 hc_log
  home=$(make_home non_destructive)
  seed_healthy_stubs "$home"
  printf 'hc\n' > "$home/config/backend"
  hc_log="$home/hc-calls.log"
  cat > "$home/fakebin/herdr-core" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$hc_log"
if [ "\${1:-}" = "server" ] && [ "\${2:-}" = "status" ]; then
  printf '{"core":{"id":"core-1","name":"host"},"finished":0,"holder":{"current":true,"instance":"inst-1","pid":4001,"terminals":1},"live":1,"pid":4000,"uptime_ms":90000000,"version":"0.1.18"}\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$home/fakebin/herdr-core"
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
  test_night_window_last_dispatch_cutoff_stops_dispatch_and_sets_reserve_flag \
  test_night_window_ended_ends_night \
  test_malformed_night_config_fails_closed_as_unknown \
  test_claude_quota_below_25_stops_claude_only \
  test_claude_quota_below_12_stops_all_dispatch \
  test_unreadable_quota_source_stops_dispatch \
  test_github_api_below_floor_and_unreadable \
  test_failure_streak_three_consecutive_stops_dispatch \
  test_dev_health_failed_post_merge_and_corrupt_ledger \
  test_check_machine_two_waiting_prs_stops_dispatch \
  test_validation_cap_two_high_stakes_runs \
  test_host_load_sustained_high_and_unreadable \
  test_supervision_stall_old_wake_latch_and_corrupt_queue \
  test_hc_core_restart_ends_night_and_unreadable_stops_dispatch \
  test_hc_guard_blocks_install_and_core_stop_paths \
  test_stop_condition_never_kills_or_tears_down_workers
