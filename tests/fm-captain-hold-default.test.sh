#!/usr/bin/env bash
# Tests for the two-hour default on captain-held tasks (bin/fm-captain-hold.sh
# hold --default-*, default, due): the default-bearing hold's refusals, the one
# stop-by-default decision function's input matrix, the defaulted provenance
# record, the read-only due listing, and bearings' "decided by default" rows.
# Every case uses an isolated fixture home, a fixture dialog mirror, and a
# stubbed night check; nothing reads a real captain record or the network.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-default)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# shellcheck source=tests/captain-hold-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/captain-hold-helpers.sh"

# 2026-11-27T07:00:00Z is the ask; 09:00:00Z is ask + 2h.
ASK_ISO=2026-11-27T07:00:00Z
ASK_EPOCH=1795762800
DUE_ISO=2026-11-27T09:00:00Z
DUE_EPOCH=1795770000
NIGHT_START=1795755600
RECOMMENDATION='Use the shorter notice copy (option B) and file the longer copy as a follow-up.'

write_mirror() {  # <home> <tag:epoch>...
  local home=$1 seq=0 entry tag epoch
  shift
  : > "$home/state/.host-mirror.jsonl"
  for entry in "$@"; do
    seq=$((seq + 1))
    tag=${entry%%:*}
    epoch=${entry#*:}
    jq -cn --argjson seq "$seq" --argjson epoch "$epoch" --arg tag "$tag" \
      '{seq:$seq,epoch:$epoch,key:"main-key",id:("e" + ($seq|tostring)),tag:$tag,text:"words",text_sha256:"x"}' \
      >> "$home/state/.host-mirror.jsonl"
  done
}

write_verdict() {  # <home> [jq filter applied to the healthy verdict]
  local home=$1 filter=${2:-.}
  jq -n --argjson now "$DUE_EPOCH" --argjson start "$NIGHT_START" '
    {schema:"fm-night-verdict.v1",checked_epoch:$now,checked_at:"2026-11-27T09:00:00Z",
     night_active:true,night_started_epoch:$start,verdict:"continue",verdict_label:"continue",
     allow:{dispatch:true,claude:true,merge:true,validation:true,two_hour_default:true},
     tripped:[],reasons:[]}' | jq "$filter" > "$home/verdict.json"
}

# A stubbed night check: prints the fixture verdict and exits with verdict.rc.
install_night_check_stub() {  # <home>
  local home=$1
  cat > "$home/night-check" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_NIGHT_LOG"
# A test's mid-check hook: what changes while the live check runs.
[ ! -f "${FM_TEST_NIGHT_HOOK:-}" ] || bash "$FM_TEST_NIGHT_HOOK"
cat "$FM_TEST_NIGHT_VERDICT"
exit "$(cat "$FM_TEST_NIGHT_RC" 2>/dev/null || echo 0)"
SH
  chmod +x "$home/night-check"
  : > "$home/night.log"
}

run_default_cmd() {  # <home> <now-iso> <command args...>
  local home=$1 now=$2
  shift 2
  FM_CAPTAIN_HOLD_NOW=$now FM_NIGHT_CHECK_BIN="$home/night-check" \
    FM_TEST_NIGHT_VERDICT="$home/verdict.json" FM_TEST_NIGHT_RC="$home/verdict.rc" \
    FM_TEST_NIGHT_LOG="$home/night.log" FM_TEST_NIGHT_HOOK="$home/hook.sh" run_captain "$home" "$@"
}

hold_with_default() {  # <home> <id> [extra hold args...]
  local home=$1 id=$2
  shift 2
  FM_CAPTAIN_HOLD_NOW=$ASK_ISO run_captain "$home" hold "$id" \
    --title "Notice copy choice $id" --reason "pick option A or B for the notice copy" \
    --repo sample --default-file "$home/rec.txt" --default-class dev-revertible \
    --default-category issue-design-choice "$@"
}

# A home whose every default input is healthy at DUE_ISO.
healthy_home() {  # <name>
  local home
  home=$(make_home "$1")
  printf '%s\n' "$RECOMMENDATION" > "$home/rec.txt"
  hold_with_default "$home" t1 >/dev/null || fail "$1: the default-bearing hold was refused"
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "main:$((ASK_EPOCH + 60))" "main:$((DUE_EPOCH - 120))"
  jq -n --argjson start "$NIGHT_START" '{schema:"fm-night-active.v1",started_epoch:$start,created_reserve_flags:[],stop_record_expected:false}' \
    > "$home/state/night-active.json"
  write_verdict "$home"
  install_night_check_stub "$home"
  printf '%s\n' "$home"
}

body_of() {  # <home> <id>
  public_show "$1" "$2" | sed -n 's/^  body: //p'
}

assert_still_held() {  # <home> <id> <label>
  run_captain "$1" open "$2" || fail "$3: the task is no longer an open captain hold"
  case "$(body_of "$1" "$2")" in
    *"Resolution mode: defaulted"*) fail "$3: a defaulted record was written" ;;
  esac
}

assert_refused() {  # <home> <label> <expected-reason-substring> [now-iso]
  local home=$1 label=$2 want=$3 now=${4:-$DUE_ISO} rc=0
  run_default_cmd "$home" "$now" default t1 > "$home/out" 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: the default applied (stdout: $(cat "$home/out"))"
  grep -F -- "$want" "$home/err" >/dev/null \
    || fail "$label: refusal did not name '$want': $(cat "$home/err")"
  assert_still_held "$home" t1 "$label"
}

refused_hold() {  # <home> <label> <expected-substring> <id> <hold args after the id...>
  local home=$1 label=$2 want=$3 id=$4 rc=0
  shift 4
  FM_CAPTAIN_HOLD_NOW=$ASK_ISO run_captain "$home" hold "$id" --title "Title $id" --reason "r" \
    --repo sample "$@" > /dev/null 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: the hold was accepted"
  grep -F -- "$want" "$home/err" > /dev/null || fail "$label: refusal did not name '$want': $(cat "$home/err")"
  [ ! -e "$home/data/$id/hold-default.json" ] || fail "$label: the refused hold left a default record"
  ! run_captain "$home" open "$id" || fail "$label: the refused hold still placed a captain hold"
}

# --- default-bearing hold ----------------------------------------------------

test_hold_refuses_an_incomplete_or_disallowed_default() {
  local home
  home=$(make_home hold-refusals)
  printf '%s\n' "$RECOMMENDATION" > "$home/rec.txt"
  : > "$home/empty.txt"
  refused_hold "$home" "always-waits category" "always waits" a1 \
    --default-file "$home/rec.txt" --default-class dev-revertible --default-category production
  refused_hold "$home" "unknown category" "unknown default category" a2 \
    --default-file "$home/rec.txt" --default-class dev-revertible --default-category made-up
  refused_hold "$home" "missing recommendation" "--default-file" a3 \
    --default-class dev-revertible --default-category issue-design-choice
  refused_hold "$home" "empty recommendation" "recommendation" a4 \
    --default-file "$home/empty.txt" --default-class dev-revertible --default-category issue-design-choice
  refused_hold "$home" "missing class" "--default-class" a5 \
    --default-file "$home/rec.txt" --default-category issue-design-choice
  refused_hold "$home" "other class" "dev-revertible" a6 \
    --default-file "$home/rec.txt" --default-class prod-anything --default-category issue-design-choice
  refused_hold "$home" "missing category" "--default-category" a7 \
    --default-file "$home/rec.txt" --default-class dev-revertible
  printf 'option\000B\n' > "$home/nul.txt"
  refused_hold "$home" "recommendation with a NUL byte" "NUL" a8 \
    --default-file "$home/nul.txt" --default-class dev-revertible --default-category issue-design-choice
  printf 'option \377B\n' > "$home/bad-utf8.txt"
  refused_hold "$home" "recommendation that is not UTF-8" "UTF-8" a9 \
    --default-file "$home/bad-utf8.txt" --default-class dev-revertible --default-category issue-design-choice
  pass "a default-bearing hold refuses always-waits, unknown, unrecommended, or unclassed defaults before writing"
}

test_hold_refuses_a_default_from_the_supervision_engine() {
  local home rc=0
  home=$(make_home hold-branch)
  printf '%s\n' "$RECOMMENDATION" > "$home/rec.txt"
  FM_SUPERVISION_ACTOR=branch hold_with_default "$home" b1 > /dev/null 2> "$home/err" || rc=$?
  { [ "$rc" -ne 0 ] && grep -F "only main" "$home/err" >/dev/null; } \
    || fail "the supervision engine (branch actor) wrote a default: $(cat "$home/err")"
  rc=0
  FM_SUPERVISION_ACTOR=stranger hold_with_default "$home" b2 > /dev/null 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown supervision actor wrote a default"
  ! run_captain "$home" open b1 || fail "the refused engine hold still placed a captain hold"
  ! run_captain "$home" open b2 || fail "the refused unknown-actor hold still placed a captain hold"
  FM_SUPERVISION_ACTOR=main hold_with_default "$home" b3 > /dev/null \
    || fail "main could not write a default-bearing hold"
  pass "only main writes a default: the supervision engine's branch actor and unknown actors are refused"
}

test_existing_hold_never_gains_a_default() {
  local home rc=0
  home=$(make_home hold-retro)
  printf '%s\n' "$RECOMMENDATION" > "$home/rec.txt"
  FM_CAPTAIN_HOLD_NOW=$ASK_ISO run_captain "$home" hold r1 --title "Notice copy choice r1" \
    --reason "pick option A or B for the notice copy" --repo sample > /dev/null \
    || fail "plain hold failed"
  hold_with_default "$home" r1 > /dev/null 2> "$home/err" || rc=$?
  { [ "$rc" -ne 0 ] && grep -F "already held" "$home/err" >/dev/null; } \
    || fail "an existing hold gained a default retroactively: $(cat "$home/err")"
  [ ! -e "$home/data/r1/hold-default.json" ] || fail "the retroactive attempt left a default record"
  pass "a hold that already exists never gains a default later"
}

test_expired_dated_hold_never_gains_a_default() {
  local home rc=0
  home=$(make_home hold-expired)
  printf '%s\n' "$RECOMMENDATION" > "$home/rec.txt"
  FM_CAPTAIN_HOLD_NOW=$ASK_ISO run_captain "$home" hold x1 --title "Notice copy choice x1" \
    --reason "pick option A or B for the notice copy" --repo sample --until 2026-01-02 > /dev/null \
    || fail "dated hold failed"
  run_captain "$home" open x1 || fail "an expired dated hold is not an open captain call"
  hold_with_default "$home" x1 > /dev/null 2> "$home/err" || rc=$?
  { [ "$rc" -ne 0 ] && grep -F "already held" "$home/err" >/dev/null; } \
    || fail "a hold past its --until date gained a default: $(cat "$home/err")"
  [ ! -e "$home/data/x1/hold-default.json" ] || fail "the expired-hold attempt left a default record"
  pass "a captain hold past its --until date is still an existing hold and never gains a default"
}

test_repeated_hold_drops_its_default_with_a_notice() {
  local home
  home=$(make_home hold-drop)
  printf '%s\n' "$RECOMMENDATION" > "$home/rec.txt"
  hold_with_default "$home" p1 > /dev/null || fail "default-bearing hold refused"
  FM_CAPTAIN_HOLD_NOW=$ASK_ISO run_captain "$home" hold p1 --reason "pick option A or B for the notice copy" \
    > /dev/null 2> "$home/err" || fail "repeated hold failed: $(cat "$home/err")"
  grep -F "dropped its recorded default" "$home/err" > /dev/null || fail "the dropped default was silent: $(cat "$home/err")"
  [ ! -e "$home/data/p1/hold-default.json" ] || fail "a repeated hold kept the earlier default"
  pass "a repeated hold drops an earlier default and says so"
}

test_default_bearing_hold_records_its_default() {
  local home
  home=$(make_home hold-records)
  printf '%s\n' "$RECOMMENDATION" > "$home/rec.txt"
  hold_with_default "$home" d1 > /dev/null || fail "default-bearing hold refused"
  run_captain "$home" open d1 || fail "default-bearing hold is not an open captain hold"
  jq -e --arg rec "$RECOMMENDATION"$'\n' --argjson ask "$ASK_EPOCH" '
      .task == "d1" and .class == "dev-revertible" and .category == "issue-design-choice"
      and .recommendation == $rec and .ask_epoch == $ask and .asked_at == "2026-11-27T07:00:00Z"' \
    "$home/data/d1/hold-default.json" > /dev/null \
    || fail "the default record does not carry the verbatim recommendation, class, category, and ask time: $(cat "$home/data/d1/hold-default.json")"
  pass "a default-bearing hold records the verbatim recommendation, class, category, and ask time"
}

# --- the decision function: healthy case and per-input refusals --------------

test_healthy_default_applies_with_defaulted_provenance() {
  local home body
  home=$(healthy_home healthy)
  run_default_cmd "$home" "$DUE_ISO" default t1 > "$home/out" 2> "$home/err" \
    || fail "healthy default refused: $(cat "$home/err")"
  grep -F "defaulted: t1" "$home/out" > /dev/null || fail "default did not report the outcome: $(cat "$home/out")"
  grep -Fx "check --json" "$home/night.log" > /dev/null || fail "the night check was not run fresh: $(cat "$home/night.log")"
  ! run_captain "$home" open t1 || fail "the defaulted task is still an open captain hold"
  body=$(body_of "$home" t1)
  case "$body" in *"Resolution mode: defaulted"*) ;; *) fail "the record does not carry defaulted provenance: $body" ;; esac
  case "$body" in *"Default reason: no answer from the owner"*) ;; *) fail "the record lacks the reason: $body" ;; esac
  case "$body" in *"Default asked at: $ASK_ISO"*) ;; *) fail "the record lacks the ask time: $body" ;; esac
  case "$body" in *"Default applied at: $DUE_ISO"*) ;; *) fail "the record lacks the apply time: $body" ;; esac
  case "$body" in *"$RECOMMENDATION"*) ;; *) fail "the record lacks the verbatim recommendation: $body" ;; esac
  case "$body" in *"Captain decision:"*) fail "the default was recorded as the captain's words: $body" ;; esac
  run_default_cmd "$home" "$DUE_ISO" default t1 > "$home/out" 2> "$home/err" \
    || fail "replaying an applied default failed: $(cat "$home/err")"
  [ "$(body_of "$home" t1 | grep -o 'Resolution mode: defaulted' | wc -l | tr -d ' ')" = 1 ] \
    || fail "replaying an applied default recorded it twice"
  pass "a healthy default applies exactly the recommendation with defaulted provenance, never as the captain's words"
}

test_interrupted_default_finishes_on_retry() {
  local home show
  home=$(healthy_home interrupted)
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = update ] && [ "${2:-}" = t1 ] && [ ! -e "$FM_HOME/normalize-failed-once" ]; then
  state=$("$REAL_TASKS_AXI" show "$2" --full | sed -n 's/^  state: //p' | head -1)
  if [ "$state" = done ]; then
    : > "$FM_HOME/normalize-failed-once"
    exit 94
  fi
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err"; then
    fail "the forced post-close normalization failure reported success"
  fi
  [ "$(public_show "$home" t1 | sed -n 's/^  state: //p')" = "done" ] || fail "the forced failure did not leave the close done"
  run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err" \
    || fail "retrying the interrupted default failed: $(cat "$home/err")"
  show=$(public_show "$home" t1)
  case "$show" in *'body: "Resolution recorded by fm-captain-hold.'*) ;; *) fail "the retry did not restore resolution-first ordering: $show" ;; esac
  [ "$(body_of "$home" t1 | grep -o 'Resolution mode: defaulted' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the retry recorded the default twice"
  run_bearings "$home" | jq -e '.decided_by_default[0].id == "t1"' > /dev/null \
    || fail "the retried default is missing from bearings"
  pass "an interrupted default finishes its close on retry without recording twice"
}

test_real_night_check_refuses_an_unhealthy_night() {
  local home
  home=$(healthy_home real-night)
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/quota-axi"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/gh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/herdr-core"
  chmod +x "$home/fakebin/quota-axi" "$home/fakebin/gh" "$home/fakebin/herdr-core"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$ROOT/bin/fm-night-check.sh" > "$home/night-check"
  chmod +x "$home/night-check"
  assert_refused "$home" "real night check on an unhealthy night" "allow.two_hour_default"
  pass "the real night check's verdict is read and an unhealthy night refuses the default"
}

test_release_default_frees_held_work_attended_only() {
  local home rc=0
  home=$(healthy_home release)
  : > "$home/state/.afk"
  run_default_cmd "$home" "$DUE_ISO" default t1 --release > /dev/null 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a releasing default applied while the away-posture record exists"
  assert_still_held "$home" t1 "release while away"
  rm -f "$home/state/.afk"
  run_default_cmd "$home" "$DUE_ISO" default t1 --release > /dev/null 2> "$home/err" \
    || fail "attended releasing default refused: $(cat "$home/err")"
  [ "$(public_show "$home" t1 | sed -n 's/^  state: //p')" != "done" ] || fail "a releasing default closed the work item"
  ! run_captain "$home" open t1 || fail "a releasing default left the captain hold"
  pass "a releasing default lifts the hold like a recorded release, and only in an attended session"
}

test_hold_input_refusals() {
  local home
  home=$(healthy_home hold-missing)
  rm -f "$home/data/t1/hold-default.json"
  assert_refused "$home" "missing default record" "no default was recorded"

  home=$(healthy_home hold-malformed)
  printf '{not json' > "$home/data/t1/hold-default.json"
  assert_refused "$home" "malformed default record" "default record"

  home=$(healthy_home hold-unreadable)
  chmod 000 "$home/data/t1/hold-default.json"
  if [ ! -r "$home/data/t1/hold-default.json" ]; then
    assert_refused "$home" "unreadable default record" "default record"
  fi
  chmod 600 "$home/data/t1/hold-default.json"

  home=$(healthy_home hold-stale)
  tasks_in "$home" hold t1 --kind captain --reason "a different question" > /dev/null \
    || fail "could not change the held question"
  assert_refused "$home" "default record from an earlier question" "question changed"

  home=$(healthy_home hold-category)
  jq '.category = "production"' "$home/data/t1/hold-default.json" > "$home/x" \
    && mv "$home/x" "$home/data/t1/hold-default.json"
  assert_refused "$home" "always-waits category in the record" "always waits"
  pass "the hold input refuses a missing, malformed, unreadable, stale, or disallowed default record"
}

test_answer_input_refusals() {
  local home rc=0
  home=$(healthy_home answer-deferred)
  printf 'later\n' > "$home/later.txt"
  FM_CAPTAIN_HOLD_NOW=2026-11-27T08:00:00Z run_captain "$home" answer t1 --decision-file "$home/later.txt" \
    --defer-until 2026-12-01 > /dev/null || fail "defer answer failed"
  assert_refused "$home" "deferred captain answer" "captain"

  home=$(healthy_home answer-closed)
  printf 'option A\n' > "$home/a.txt"
  run_captain "$home" answer t1 --decision-file "$home/a.txt" > /dev/null || fail "answer failed"
  run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a default applied over the captain's recorded answer"
  case "$(body_of "$home" t1)" in *"Resolution mode: defaulted"*) fail "a default overwrote the captain's answer" ;; esac
  pass "the answer input refuses once the captain has answered or deferred"
}

test_time_input_refusals() {
  local home
  home=$(healthy_home time-early)
  write_mirror "$home" "captain:$((ASK_EPOCH - 3600))" "main:$((ASK_EPOCH + 60))"
  assert_refused "$home" "before ask + 2h" "7200" 2026-11-27T08:59:59Z
  home=$(healthy_home time-future)
  assert_refused "$home" "ask time in the future" "future" 2026-11-27T06:00:00Z
  pass "the time input refuses before ask + 7200s and for an ask in the future"
}

test_mirror_input_refusals() {
  local home
  home=$(healthy_home mirror-missing)
  rm -f "$home/state/.host-mirror.jsonl"
  assert_refused "$home" "missing mirror" "dialog mirror"

  home=$(healthy_home mirror-malformed)
  printf '{"seq":1,"epoch":1,"key":"k","tag":"captain","text":"x"}\n{broken\n' > "$home/state/.host-mirror.jsonl"
  assert_refused "$home" "malformed mirror" "dialog mirror"

  home=$(healthy_home mirror-epochless)
  printf '%s\n' '{"seq":1,"key":"k","tag":"captain","text":"x"}' \
    "{\"seq\":2,\"epoch\":$((DUE_EPOCH - 60)),\"key\":\"k\",\"tag\":\"main\",\"text\":\"y\"}" \
    > "$home/state/.host-mirror.jsonl"
  assert_refused "$home" "captain entry without an epoch" "epoch"

  home=$(healthy_home mirror-unreadable)
  chmod 000 "$home/state/.host-mirror.jsonl"
  if [ ! -r "$home/state/.host-mirror.jsonl" ]; then
    assert_refused "$home" "unreadable mirror" "dialog mirror"
  fi
  chmod 600 "$home/state/.host-mirror.jsonl"

  home=$(healthy_home mirror-stale)
  write_mirror "$home" "captain:$((ASK_EPOCH - 7200))" "main:$((ASK_EPOCH - 60))"
  assert_refused "$home" "mirror with no entry since the ask" "since the ask"

  home=$(healthy_home mirror-future)
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "main:$((DUE_EPOCH + 600))"
  assert_refused "$home" "mirror entry in the future" "future"
  pass "the mirror input refuses a missing, malformed, unreadable, stale, or future mirror"
}

# The last hour before DUE_ISO starts at DUE_EPOCH - 3600 (= ASK_EPOCH + 3600).

test_trimmed_mirror_reaching_back_an_hour_applies() {
  local home
  home=$(healthy_home mirror-trimmed)
  write_mirror "$home" "main:$((DUE_EPOCH - 3600))" "main:$((DUE_EPOCH - 1800))" "main:$((DUE_EPOCH - 60))"
  run_default_cmd "$home" "$DUE_ISO" default t1 > "$home/out" 2> "$home/err" \
    || fail "a trimmed mirror whose oldest kept entry is at now-3600 refused: $(cat "$home/err")"
  grep -F "defaulted: t1" "$home/out" > /dev/null || fail "the trimmed-mirror default did not apply: $(cat "$home/out")"
  pass "a trimmed mirror with no captain entry kept, whose oldest entry is at or before now-3600, applies"
}

test_mirror_not_reaching_back_an_hour_stops() {
  local home
  home=$(healthy_home mirror-short)
  write_mirror "$home" "main:$((DUE_EPOCH - 3599))" "main:$((DUE_EPOCH - 60))"
  assert_refused "$home" "mirror newer than now-3600 with no captain entry" "does not reach back"
  pass "a mirror whose oldest entry is newer than now-3600 and holds no captain entry stops: it does not reach back an hour"
}

test_captain_entry_inside_the_last_hour_stops() {
  local home
  home=$(healthy_home mirror-recent-captain)
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "main:$((ASK_EPOCH + 60))" "captain:$((DUE_EPOCH - 3599))"
  assert_refused "$home" "captain message within the last hour" "newest captain message"
  pass "a captain entry inside the last hour stops the default"
}

test_owner_entry_at_exactly_now_minus_3600_counts_inside_the_hour() {
  local home
  home=$(healthy_home mirror-boundary-captain)
  write_mirror "$home" "main:$((ASK_EPOCH + 60))" "captain:$((DUE_EPOCH - 3600))" "main:$((DUE_EPOCH - 60))"
  assert_refused "$home" "captain message at exactly now-3600" "newest captain message is 3600s old"
  pass "an owner entry at exactly now-3600 counts inside the hour and stops"
}

test_out_of_order_mirror_stops_as_invalid() {
  local home
  home=$(healthy_home mirror-unordered)
  write_mirror "$home" "main:$((ASK_EPOCH - 600))" "main:$((ASK_EPOCH + 60))" "main:$((ASK_EPOCH - 300))" "main:$((DUE_EPOCH - 60))"
  assert_refused "$home" "entry epochs out of order" "out of epoch order"

  home=$(healthy_home mirror-oldest-newer)
  write_mirror "$home" "main:$((DUE_EPOCH - 1800))" "main:$((ASK_EPOCH - 600))" "main:$((DUE_EPOCH - 60))"
  assert_refused "$home" "first kept entry newer than its neighbour" "out of epoch order"
  pass "a mirror whose entries are out of epoch order, including a first kept entry newer than its neighbour, stops as invalid rather than as coverage"
}

test_night_check_input_refusals() {
  local home
  home=$(healthy_home night-missing)
  rm -f "$home/night-check"
  assert_refused "$home" "missing night check" "night check"

  home=$(healthy_home night-failed)
  printf '1\n' > "$home/verdict.rc"
  assert_refused "$home" "night check exits nonzero" "night check"

  home=$(healthy_home night-malformed)
  printf 'not json\n' > "$home/verdict.json"
  assert_refused "$home" "malformed verdict" "night check"

  home=$(healthy_home night-stale)
  write_verdict "$home" ".checked_epoch = $((DUE_EPOCH - 1))"
  assert_refused "$home" "verdict older than this run" "stale"

  home=$(healthy_home night-disallowed)
  write_verdict "$home" '.allow.two_hour_default = false | .verdict = "stop_dispatch"'
  assert_refused "$home" "verdict disallows the default" "two_hour_default"

  home=$(healthy_home night-inactive)
  write_verdict "$home" '.night_active = false'
  assert_refused "$home" "no active night in the verdict" "night"

  home=$(healthy_home night-other)
  write_verdict "$home" ".night_started_epoch = $((NIGHT_START + 1))"
  assert_refused "$home" "verdict from another night" "night_started_epoch"

  home=$(healthy_home night-no-active-record)
  rm -f "$home/state/night-active.json"
  assert_refused "$home" "no active night record" "night-active"
  pass "the night-check input refuses a missing, failed, malformed, stale, disallowing, inactive, or other-night verdict"
}

# --- due listing -----------------------------------------------------------

test_due_lists_without_changing_anything() {
  local home before out
  home=$(healthy_home due)
  before=$(body_of "$home" t1)
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "main:$((ASK_EPOCH + 60))"
  out=$(run_default_cmd "$home" 2026-11-27T07:30:00Z due) || fail "due failed early"
  case "$out" in *"t1 waits"*) ;; *) fail "due before ask + 1h did not report waiting: $out" ;; esac
  out=$(run_default_cmd "$home" 2026-11-27T08:05:00Z due) || fail "due failed at ask + 1h"
  case "$out" in *"t1 proceeds at 09:00 UTC"*) ;; *) fail "due at ask + 1h did not report proceeds at 09:00 UTC: $out" ;; esac
  out=$(run_default_cmd "$home" "$DUE_ISO" due) || fail "due failed at ask + 2h"
  case "$out" in *"t1 due now"*) ;; *) fail "due at ask + 2h did not report due now: $out" ;; esac
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "captain:$((DUE_EPOCH - 300))"
  out=$(run_default_cmd "$home" "$DUE_ISO" due) || fail "due failed after a captain message"
  case "$out" in *"t1 waits for the captain"*) ;; *) fail "due after a recent captain message did not report waiting for the captain: $out" ;; esac
  write_mirror "$home" "main:$((DUE_EPOCH - 1800))" "main:$((DUE_EPOCH - 60))"
  out=$(run_default_cmd "$home" "$DUE_ISO" due) || fail "due failed on a short mirror"
  case "$out" in *"t1 unknown: dialog mirror:"*"does not reach back"*) ;; *) fail "due on a mirror not reaching back an hour did not report unknown: $out" ;; esac
  [ "$(body_of "$home" t1)" = "$before" ] || fail "due changed the held task"
  run_captain "$home" open t1 || fail "due released the hold"
  [ ! -s "$home/night.log" ] || fail "due ran the night check"
  pass "due lists each default-bearing hold as waiting, proceeds at HH:MM, due now, or unknown, and changes nothing"
}

test_due_reports_an_unbound_default_and_skips_a_closed_hold() {
  local home out
  home=$(healthy_home due-unbound)
  tasks_in "$home" hold t1 --kind captain --reason "a different question" > /dev/null \
    || fail "could not change the held question"
  out=$(FM_CAPTAIN_HOLD_NOW=$DUE_ISO run_captain "$home" due) || fail "due failed on an unbound default"
  case "$out" in *"t1 unknown: hold: the held question changed"*) ;; *) fail "due hid a default no longer bound to its question: $out" ;; esac

  home=$(healthy_home due-closed)
  printf 'option A\n' > "$home/a.txt"
  run_captain "$home" answer t1 --decision-file "$home/a.txt" > /dev/null || fail "answer failed"
  out=$(FM_CAPTAIN_HOLD_NOW=$DUE_ISO run_captain "$home" due) || fail "due failed after the captain answered"
  case "$out" in *t1*) fail "due listed a call the captain already answered: $out" ;; esac
  pass "due reports a default no longer bound to its call as unknown and skips a call that is no longer held"
}

# --- bearings ------------------------------------------------------------------

test_bearings_shows_decided_by_default_separately() {
  local home json
  home=$(healthy_home bearings)
  run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err" \
    || fail "default refused: $(cat "$home/err")"
  printf 'option A\n' > "$home/a.txt"
  FM_CAPTAIN_HOLD_NOW=$ASK_ISO run_captain "$home" hold t2 --title "Captain answered call" \
    --reason "pick one" --repo sample > /dev/null || fail "plain hold failed"
  run_captain "$home" answer t2 --decision-file "$home/a.txt" > /dev/null || fail "answer failed"
  json=$(run_bearings "$home") || fail "bearings failed"
  printf '%s' "$json" | jq -e --arg rec "$RECOMMENDATION"$'\n' --arg ask "$ASK_ISO" --arg applied "$DUE_ISO" '
      (.decided_by_default | length) == 1
      and .decided_by_default[0].id == "t1"
      and .decided_by_default[0].recommendation == $rec
      and .decided_by_default[0].asked_at == $ask
      and .decided_by_default[0].applied_at == $applied' > /dev/null \
    || fail "bearings did not list the defaulted decision with its recommendation and times: $(printf '%s' "$json" | jq -c '.decided_by_default')"
  pass "bearings lists decisions settled by default separately from captain answers"
}

test_bearings_bounds_decided_by_default_with_omitted_disclosure() {
  local home json later_iso=2026-11-27T09:01:00Z
  home=$(healthy_home bearings-cap)
  run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err" \
    || fail "first default refused: $(cat "$home/err")"
  hold_with_default "$home" t2 > /dev/null || fail "second default-bearing hold refused"
  write_verdict "$home" ".checked_epoch = $((DUE_EPOCH + 60))"
  run_default_cmd "$home" "$later_iso" default t2 > /dev/null 2> "$home/err" \
    || fail "second default refused: $(cat "$home/err")"
  json=$(FM_BEARINGS_DEFAULTED=1 run_bearings "$home") || fail "bearings failed"
  printf '%s' "$json" | jq -e '
      (.decided_by_default | length) == 1
      and .decided_by_default[0].id == "t2"
      and any(.omitted[]; .surface == "decided_by_default showing 1 of 2" and .reveal == "--all-landed")' > /dev/null \
    || fail "bearings did not cap decided_by_default newest first with an omitted disclosure: $(printf '%s' "$json" | jq -c '{d:.decided_by_default,o:.omitted}')"
  json=$(FM_BEARINGS_DEFAULTED=1 run_bearings "$home" --all-landed) || fail "bearings --all-landed failed"
  printf '%s' "$json" | jq -e '(.decided_by_default | map(.id)) == ["t2","t1"]
      and all(.omitted[]; (.surface | startswith("decided_by_default")) | not)' > /dev/null \
    || fail "--all-landed did not reveal every decided-by-default row: $(printf '%s' "$json" | jq -c '.decided_by_default')"
  pass "bearings bounds decided_by_default newest applied first, discloses the rest in omitted[], and --all-landed reveals them"
}

# --- review round: current night, one parse, retry, due, verbatim, wording --

# Writes a mid-check hook script for the stubbed night check.
night_hook() {  # <home> <shell text run while the check runs>
  printf '%s\n' "$2" > "$1/hook.sh"
}

test_night_ending_during_the_check_refuses() {
  local home
  home=$(healthy_home night-ends)
  night_hook "$home" "rm -f '$home/state/night-active.json'"
  assert_refused "$home" "night ends while the check runs" "after the night check ran, night check: no readable night-active record"
  pass "a night that ends while the live check runs refuses the default"
}

test_night_replaced_during_the_check_refuses() {
  local home
  home=$(healthy_home night-replaced)
  night_hook "$home" "printf '%s\n' '{\"schema\":\"fm-night-active.v1\",\"started_epoch\":$((NIGHT_START + 60)),\"created_reserve_flags\":[],\"stop_record_expected\":false}' > '$home/state/night-active.json'"
  assert_refused "$home" "night replaced while the check runs" "the active night changed while the night check ran"
  pass "a night replaced while the live check runs refuses the default"
}

test_matching_future_night_start_refuses() {
  local home
  home=$(healthy_home night-future)
  jq -n --argjson start "$((DUE_EPOCH + 60))" '{schema:"fm-night-active.v1",started_epoch:$start,created_reserve_flags:[],stop_record_expected:false}' \
    > "$home/state/night-active.json"
  write_verdict "$home" ".night_started_epoch = $((DUE_EPOCH + 60))"
  assert_refused "$home" "matching future night start" "is after the verdict's check"
  pass "a night whose matching start is after the verdict's check refuses the default"
}

test_apply_time_is_the_final_clock_sample() {
  local home ask_epoch ask_iso real_now t0 checked applied applied_epoch
  home=$(make_home advancing-clock)
  real_now=$(date -u +%s)
  ask_epoch=$((real_now - 10800))
  ask_iso=$(date -u -d "@$ask_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$ask_epoch" +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$RECOMMENDATION" > "$home/rec.txt"
  FM_CAPTAIN_HOLD_NOW=$ask_iso run_captain "$home" hold t1 --title "Notice copy choice t1" \
    --reason "pick option A or B for the notice copy" --repo sample --default-file "$home/rec.txt" \
    --default-class dev-revertible --default-category issue-design-choice > /dev/null \
    || fail "advancing clock: the default-bearing hold was refused"
  write_mirror "$home" "captain:$((ask_epoch - 600))" "main:$((real_now - 60))"
  jq -n --argjson start "$((ask_epoch - 3600))" '{schema:"fm-night-active.v1",started_epoch:$start,created_reserve_flags:[],stop_record_expected:false}' \
    > "$home/state/night-active.json"
  # A real-clock night check that takes two seconds and reports when it checked.
  cat > "$home/night-check" <<SH
#!/usr/bin/env bash
sleep 2
checked=\$(date -u +%s)
printf '%s\n' "\$checked" > '$home/checked'
jq -n --argjson now "\$checked" --argjson start "$((ask_epoch - 3600))" '{schema:"fm-night-verdict.v1",checked_epoch:\$now,
  night_active:true,night_started_epoch:\$start,verdict:"continue",allow:{two_hour_default:true}}'
SH
  chmod +x "$home/night-check"
  t0=$(date -u +%s)
  FM_NIGHT_CHECK_BIN="$home/night-check" run_captain "$home" default t1 > /dev/null 2> "$home/err" \
    || fail "advancing clock: the default refused: $(cat "$home/err")"
  checked=$(cat "$home/checked")
  applied=$(body_of "$home" t1 | jq -r . | sed -n 's/^Default applied at: //p')
  applied_epoch=$(date -u -d "$applied" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$applied" +%s)
  [ "$checked" -ge $((t0 + 2)) ] || fail "advancing clock: the check did not take its two seconds"
  [ "$applied_epoch" -ge "$checked" ] \
    || fail "advancing clock: apply time $applied is before the night check's $checked, so it is not the final sample"
  pass "with an advancing clock the recorded apply time is the final clock sample, after the night check"
}

test_sidecar_with_an_extra_json_record_refuses() {
  local home
  home=$(healthy_home sidecar-stream)
  jq -c . "$home/data/t1/hold-default.json" > "$home/one.json"
  cat "$home/one.json" "$home/one.json" > "$home/data/t1/hold-default.json"
  assert_refused "$home" "default record with an extra JSON record" "is malformed"
  pass "a default record holding more than one JSON value refuses the default"
}

test_verdict_with_a_string_night_start_refuses() {
  local home
  home=$(healthy_home verdict-string-start)
  write_verdict "$home" ".night_started_epoch = \"$NIGHT_START\""
  assert_refused "$home" "verdict with a string started epoch" "does not match the active night"
  pass "a verdict whose night start is a string never matches the numeric active start"
}

test_mirror_replaced_during_the_check_with_an_older_quiet_snapshot_refuses() {
  local home
  home=$(healthy_home mirror-swapped)
  night_hook "$home" "rm -f '$home/state/.host-mirror.jsonl'
printf '%s\n' '{\"seq\":1,\"epoch\":$((ASK_EPOCH - 5000)),\"key\":\"main-key\",\"id\":\"e1\",\"tag\":\"main\",\"text\":\"w\",\"text_sha256\":\"x\"}' \
  '{\"seq\":2,\"epoch\":$((ASK_EPOCH - 4000)),\"key\":\"main-key\",\"id\":\"e2\",\"tag\":\"main\",\"text\":\"w\",\"text_sha256\":\"x\"}' \
  > '$home/state/.host-mirror.jsonl'"
  assert_refused "$home" "mirror swapped for an older quiet snapshot" "after the night check ran, dialog mirror: no entry is recorded since the ask"
  pass "a mirror replaced during the night check with an older quiet snapshot refuses the default"
}

# A tasks-axi that fails <verb> on t1 once, then behaves.
fail_tasks_axi_once() {  # <home> <verb>
  cat > "$1/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "$2" ] && [ "\${2:-}" = t1 ] && [ ! -e "\$FM_HOME/$2-failed-once" ]; then
  : > "\$FM_HOME/$2-failed-once"
  exit 94
fi
exec "\$REAL_TASKS_AXI" "\$@"
EOF
  chmod +x "$1/fakebin/tasks-axi"
}

assert_unchanged_since() {  # <home> <before-body> <label>
  [ "$(body_of "$1" t1)" = "$2" ] || fail "$3: the task body changed"
  run_captain "$1" open t1 || fail "$3: the task is no longer an open captain hold"
}

test_retry_after_a_failed_close_keeps_the_persisted_disposition() {
  local home before rc=0
  home=$(healthy_home retry-close)
  fail_tasks_axi_once "$home" "done"
  ! run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err" \
    || fail "a failed close reported success"
  before=$(body_of "$home" t1)
  case "$before" in *"Default disposition: close"*) ;; *) fail "the defaulted record did not persist its close disposition: $before" ;; esac
  run_default_cmd "$home" "$DUE_ISO" default t1 --release > /dev/null 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a releasing retry of a close was accepted"
  grep -F "defaulted to close" "$home/err" > /dev/null || fail "the mismatched retry did not name the disposition: $(cat "$home/err")"
  assert_unchanged_since "$home" "$before" "mismatched retry of a close"
  run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err" \
    || fail "the exact retry of a failed close refused: $(cat "$home/err")"
  [ "$(public_show "$home" t1 | sed -n 's/^  state: //p')" = "done" ] || fail "the exact retry did not close the task"
  [ "$(body_of "$home" t1 | grep -o 'Resolution mode: defaulted' | wc -l | tr -d ' ')" = 1 ] || fail "the retry recorded the default twice"
  pass "after a failed close the exact retry closes, and a releasing retry refuses without changing anything"
}

test_retry_after_a_failed_release_keeps_the_persisted_disposition() {
  local home before rc=0
  home=$(healthy_home retry-release)
  fail_tasks_axi_once "$home" unhold
  ! run_default_cmd "$home" "$DUE_ISO" default t1 --release > /dev/null 2> "$home/err" \
    || fail "a failed release reported success"
  before=$(body_of "$home" t1)
  case "$before" in *"Default disposition: release"*) ;; *) fail "the defaulted record did not persist its release disposition: $before" ;; esac
  run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a closing retry of a release was accepted"
  grep -F "defaulted to release" "$home/err" > /dev/null || fail "the mismatched retry did not name the disposition: $(cat "$home/err")"
  assert_unchanged_since "$home" "$before" "mismatched retry of a release"
  run_default_cmd "$home" "$DUE_ISO" default t1 --release > /dev/null 2> "$home/err" \
    || fail "the exact retry of a failed release refused: $(cat "$home/err")"
  [ "$(public_show "$home" t1 | sed -n 's/^  state: //p')" != "done" ] || fail "the release retry closed the work item"
  ! run_captain "$home" open t1 || fail "the exact release retry left the captain hold"
  pass "after a failed release the exact retry releases, and a closing retry refuses without changing anything"
}

test_retry_after_a_rehold_with_a_changed_question_refuses() {
  local home rc=0
  home=$(healthy_home retry-reheld)
  fail_tasks_axi_once "$home" "done"
  ! run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err" \
    || fail "a failed close reported success"
  FM_CAPTAIN_HOLD_NOW=2026-11-27T09:10:00Z run_captain "$home" hold t1 --reason "a different question for the captain" \
    > /dev/null 2> "$home/err" || fail "re-holding with a changed question failed: $(cat "$home/err")"
  run_default_cmd "$home" "2026-11-27T09:20:00Z" default t1 > /dev/null 2> "$home/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "the retry closed the newly held question"
  grep -F "retry refused for t1" "$home/err" > /dev/null || fail "the retry refusal did not name the retry: $(cat "$home/err")"
  run_captain "$home" open t1 || fail "the new question is no longer held"
  [ "$(public_show "$home" t1 | sed -n 's/^  state: //p')" != "done" ] || fail "the new question was closed"
  pass "a re-hold with a changed question between a failed close and its retry makes the retry refuse"
}

test_new_default_applies_after_a_released_default() {
  local home out body second='Ship option A for the banner and file option B as a follow-up.'
  home=$(healthy_home rehold-after-release)
  run_default_cmd "$home" "$DUE_ISO" default t1 --release > /dev/null 2> "$home/err" \
    || fail "the first releasing default refused: $(cat "$home/err")"
  ! run_captain "$home" open t1 || fail "the releasing default left the captain hold"
  printf '%s\n' "$second" > "$home/rec2.txt"
  FM_CAPTAIN_HOLD_NOW=2026-11-27T10:00:00Z run_captain "$home" hold t1 \
    --title "Notice copy choice t1" --reason "pick option A or B for the banner" --repo sample \
    --default-file "$home/rec2.txt" --default-class dev-revertible --default-category issue-design-choice \
    > /dev/null 2> "$home/err" || fail "the new default-bearing hold was refused: $(cat "$home/err")"
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "main:$((ASK_EPOCH + 60))" "main:$((DUE_EPOCH - 120))" \
    "main:$((DUE_EPOCH + 3660))" "main:$((DUE_EPOCH + 10680))"
  write_verdict "$home" ".checked_epoch = $((DUE_EPOCH + 10800)) | .checked_at = \"2026-11-27T12:00:00Z\""
  out=$(FM_CAPTAIN_HOLD_NOW=2026-11-27T12:00:00Z run_captain "$home" due) || fail "due failed on the new hold"
  [ "$out" = "t1 due now" ] || fail "due did not list the new default as due now: $out"
  run_default_cmd "$home" 2026-11-27T12:00:00Z default t1 > "$home/out" 2> "$home/err" \
    || fail "the new default refused while due listed it as due now: $(cat "$home/err")"
  grep -Fx "defaulted: t1" "$home/out" > /dev/null || fail "default did not report the outcome: $(cat "$home/out")"
  [ "$(public_show "$home" t1 | sed -n 's/^  state: //p')" = "done" ] || fail "the new default did not close the task"
  body=$(body_of "$home" t1)
  [ "$(printf '%s' "$body" | grep -o 'Resolution mode: defaulted' | wc -l | tr -d ' ')" = 2 ] \
    || fail "the new default was not recorded as a second defaulted resolution: $body"
  case "$body" in *"Default asked at: 2026-11-27T10:00:00Z"*) ;; *) fail "the record lacks the new ask time: $body" ;; esac
  case "$body" in *"$second"*) ;; *) fail "the record lacks the new recommendation: $body" ;; esac
  pass "after a released default, a new default-bearing hold on the same item applies at ask + 2h, as due reports"
}

test_due_reports_a_mirror_wholly_before_the_ask_as_unknown() {
  local home out
  home=$(healthy_home due-stale-mirror)
  write_mirror "$home" "main:$((ASK_EPOCH - 5000))" "main:$((ASK_EPOCH - 4000))"
  out=$(FM_CAPTAIN_HOLD_NOW=$DUE_ISO run_captain "$home" due) || fail "due failed on a stale mirror"
  case "$out" in *"t1 unknown: dialog mirror: no entry is recorded since the ask"*) ;; *) fail "due on a mirror wholly before the ask did not report unknown: $out" ;; esac
  pass "due reports a mirror holding nothing since the ask as unknown, never due now"
}

test_due_reports_a_future_ask_as_unknown() {
  local home out
  home=$(healthy_home due-future-ask)
  out=$(FM_CAPTAIN_HOLD_NOW=2026-11-27T06:00:00Z run_captain "$home" due) || fail "due failed before the ask"
  case "$out" in *"t1 unknown: time: the ask time $ASK_ISO is in the future"*) ;; *) fail "due before the ask did not report unknown: $out" ;; esac
  pass "due reports an ask in the future as unknown"
}

test_due_skips_a_deferred_call() {
  local home out
  home=$(healthy_home due-deferred)
  printf 'later\n' > "$home/later.txt"
  FM_CAPTAIN_HOLD_NOW=2026-11-27T08:00:00Z run_captain "$home" answer t1 --decision-file "$home/later.txt" \
    --defer-until 2026-12-01 > /dev/null || fail "defer answer failed"
  out=$(FM_CAPTAIN_HOLD_NOW=$DUE_ISO run_captain "$home" due) || fail "due failed after a deferral"
  case "$out" in *t1*) fail "due listed a deferred call: $out" ;; esac
  pass "due skips a call the captain deferred"
}

test_recommendation_round_trips_byte_for_byte() {
  local home json
  home=$(make_home verbatim)
  printf '  indented first line\n\nDefault decision ends.\n\tlast line "quoted" \\ end\n\n' > "$home/rec.txt"
  hold_with_default "$home" t1 > /dev/null || fail "verbatim: the default-bearing hold was refused"
  jq -j .recommendation "$home/data/t1/hold-default.json" | cmp -s - "$home/rec.txt" \
    || fail "verbatim: the default record did not keep the recommendation byte for byte"
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "main:$((ASK_EPOCH + 60))" "main:$((DUE_EPOCH - 120))"
  jq -n --argjson start "$NIGHT_START" '{schema:"fm-night-active.v1",started_epoch:$start,created_reserve_flags:[],stop_record_expected:false}' \
    > "$home/state/night-active.json"
  write_verdict "$home"
  install_night_check_stub "$home"
  run_default_cmd "$home" "$DUE_ISO" default t1 > /dev/null 2> "$home/err" \
    || fail "verbatim: the default refused: $(cat "$home/err")"
  body_of "$home" t1 | jq -r . | sed -n '/^Default decision:$/{n;p;q;}' | jq -j . | cmp -s - "$home/rec.txt" \
    || fail "verbatim: the resolution record did not keep the recommendation byte for byte: $(body_of "$home" t1)"
  json=$(run_bearings "$home") || fail "verbatim: bearings failed"
  printf '%s' "$json" | jq -j '.decided_by_default[0].recommendation' | cmp -s - "$home/rec.txt" \
    || fail "verbatim: the bearings row did not keep the recommendation byte for byte: $(printf '%s' "$json" | jq -c '.decided_by_default')"
  pass "a recommendation with indentation, a blank line, the old end marker, and trailing newlines round-trips byte for byte"
}

test_real_refusing_check_changes_no_task_or_hold_data() {
  local home before after
  home=$(healthy_home real-refusal-data)
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/quota-axi"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/gh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/herdr-core"
  chmod +x "$home/fakebin/quota-axi" "$home/fakebin/gh" "$home/fakebin/herdr-core"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$ROOT/bin/fm-night-check.sh" > "$home/night-check"
  chmod +x "$home/night-check"
  [ ! -e "$home/state/night-verdict.json" ] || fail "the fixture already held a night verdict"
  before=$(cat "$home/data/backlog.md" "$home/data/t1/hold-default.json")
  assert_refused "$home" "real refusing night check" "allow.two_hour_default"
  after=$(cat "$home/data/backlog.md" "$home/data/t1/hold-default.json")
  [ "$before" = "$after" ] || fail "a refused default changed the task or hold data"
  [ -f "$home/state/night-verdict.json" ] || fail "the live night check did not record its own verdict"
  pass "a refusal from the real night check writes no task or hold change, while the check records its own verdict"
}

# Replaces the active-night record while the live check runs, keeping its
# start: a jq filter on the healthy record, or "sh:<command>" with @HOME@ for
# the fixture home.
final_night_record_case() {  # <label> <filter-or-sh>
  local label=$1 action=$2 home
  home=$(healthy_home "final-night-$label")
  case "$action" in
    sh:*) action=${action#sh:}; night_hook "$home" "${action//@HOME@/$home}" ;;
    *) night_hook "$home" "jq -c '$action' '$home/state/night-active.json' > '$home/na.tmp' && mv '$home/na.tmp' '$home/state/night-active.json'" ;;
  esac
  assert_refused "$home" "final night record: $label" "after the night check ran, night check:"
}

test_final_night_record_same_start_malformed_reserve_flags_refuses() {
  final_night_record_case same-start-reserve-flags-true '.created_reserve_flags = true'
  pass "a final night record with the same start but created_reserve_flags true refuses the default"
}

test_final_night_record_validates_every_field() {
  final_night_record_case schema-wrong-type '.schema = 1'
  final_night_record_case schema-removed 'del(.schema)'
  final_night_record_case started_epoch-wrong-type ".started_epoch = \"$NIGHT_START\""
  final_night_record_case started_epoch-removed 'del(.started_epoch)'
  final_night_record_case created_reserve_flags-wrong-type '.created_reserve_flags = "none"'
  final_night_record_case created_reserve_flags-removed 'del(.created_reserve_flags)'
  final_night_record_case stop_record_expected-wrong-type '.stop_record_expected = "no"'
  final_night_record_case stop_record_expected-removed 'del(.stop_record_expected)'
  final_night_record_case truncated "sh:head -c 20 '@HOME@/state/night-active.json' > '@HOME@/na.tmp' && mv '@HOME@/na.tmp' '@HOME@/state/night-active.json'"
  final_night_record_case unreadable "sh:chmod 000 '@HOME@/state/night-active.json'"
  final_night_record_case extra-stream "sh:jq -c . '@HOME@/state/night-active.json' > '@HOME@/na.one' && cat '@HOME@/na.one' '@HOME@/na.one' > '@HOME@/state/night-active.json'"
  pass "the final read of the night record refuses each field with a wrong type or removed, and a truncated, unreadable, or multi-value record"
}

test_verdict_label_of_any_type_is_never_printed() {
  local home label
  for label in object null; do
    home=$(healthy_home "verdict-label-$label")
    if [ "$label" = object ]; then
      write_verdict "$home" '.allow.two_hour_default = false | .verdict = {odd:"shape"}'
    else
      write_verdict "$home" '.allow.two_hour_default = false | .verdict = null'
    fi
    assert_refused "$home" "verdict label $label" "allow.two_hour_default is not true"
    ! grep -E 'odd|shape|null|\(verdict' "$home/err" > /dev/null \
      || fail "verdict label $label: the refusal printed the label: $(cat "$home/err")"
  done
  pass "a disallowing verdict refuses without printing its label, whatever its type"
}

test_due_skips_a_deferred_call_with_a_retired_category() {
  local home out
  home=$(healthy_home due-deferred-retired)
  printf 'later\n' > "$home/later.txt"
  FM_CAPTAIN_HOLD_NOW=2026-11-27T08:00:00Z run_captain "$home" answer t1 --decision-file "$home/later.txt" \
    --defer-until 2026-12-01 > /dev/null || fail "defer answer failed"
  jq '.category = "retired-category"' "$home/data/t1/hold-default.json" > "$home/hd.tmp" \
    && mv "$home/hd.tmp" "$home/data/t1/hold-default.json"
  out=$(run_default_cmd "$home" "$DUE_ISO" due) || fail "due failed after a deferral"
  case "$out" in *t1*) fail "due listed a deferred call whose category was retired: $out" ;; esac
  pass "due skips a deferred call even when its default's category is no longer on the list"
}

fm_test_run \
  test_hold_refuses_an_incomplete_or_disallowed_default \
  test_hold_refuses_a_default_from_the_supervision_engine \
  test_existing_hold_never_gains_a_default \
  test_expired_dated_hold_never_gains_a_default \
  test_repeated_hold_drops_its_default_with_a_notice \
  test_default_bearing_hold_records_its_default \
  test_healthy_default_applies_with_defaulted_provenance \
  test_interrupted_default_finishes_on_retry \
  test_real_night_check_refuses_an_unhealthy_night \
  test_release_default_frees_held_work_attended_only \
  test_hold_input_refusals \
  test_answer_input_refusals \
  test_time_input_refusals \
  test_mirror_input_refusals \
  test_trimmed_mirror_reaching_back_an_hour_applies \
  test_mirror_not_reaching_back_an_hour_stops \
  test_captain_entry_inside_the_last_hour_stops \
  test_owner_entry_at_exactly_now_minus_3600_counts_inside_the_hour \
  test_out_of_order_mirror_stops_as_invalid \
  test_night_check_input_refusals \
  test_due_lists_without_changing_anything \
  test_due_reports_an_unbound_default_and_skips_a_closed_hold \
  test_bearings_shows_decided_by_default_separately \
  test_bearings_bounds_decided_by_default_with_omitted_disclosure \
  test_night_ending_during_the_check_refuses \
  test_night_replaced_during_the_check_refuses \
  test_matching_future_night_start_refuses \
  test_apply_time_is_the_final_clock_sample \
  test_sidecar_with_an_extra_json_record_refuses \
  test_verdict_with_a_string_night_start_refuses \
  test_mirror_replaced_during_the_check_with_an_older_quiet_snapshot_refuses \
  test_retry_after_a_failed_close_keeps_the_persisted_disposition \
  test_retry_after_a_failed_release_keeps_the_persisted_disposition \
  test_retry_after_a_rehold_with_a_changed_question_refuses \
  test_new_default_applies_after_a_released_default \
  test_due_reports_a_mirror_wholly_before_the_ask_as_unknown \
  test_due_reports_a_future_ask_as_unknown \
  test_due_skips_a_deferred_call \
  test_recommendation_round_trips_byte_for_byte \
  test_real_refusing_check_changes_no_task_or_hold_data \
  test_final_night_record_same_start_malformed_reserve_flags_refuses \
  test_final_night_record_validates_every_field \
  test_verdict_label_of_any_type_is_never_printed \
  test_due_skips_a_deferred_call_with_a_retired_category
