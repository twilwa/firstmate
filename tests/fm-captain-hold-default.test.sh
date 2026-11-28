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
    FM_TEST_NIGHT_LOG="$home/night.log" run_captain "$home" "$@"
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
  jq -n --argjson start "$NIGHT_START" '{schema:"fm-night-active.v1",started_epoch:$start,created_reserve_flags:[]}' \
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
  jq -e --arg rec "$RECOMMENDATION" --argjson ask "$ASK_EPOCH" '
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

  home=$(healthy_home mirror-no-captain)
  write_mirror "$home" "main:$((ASK_EPOCH + 60))" "main:$((DUE_EPOCH - 60))"
  assert_refused "$home" "mirror with no captain message" "no captain message"

  home=$(healthy_home mirror-recent-captain)
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "main:$((ASK_EPOCH + 60))" "captain:$((DUE_EPOCH - 3599))"
  assert_refused "$home" "captain message within the last hour" "3600"

  home=$(healthy_home mirror-future)
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "main:$((DUE_EPOCH + 600))"
  assert_refused "$home" "mirror entry in the future" "future"
  pass "the mirror input refuses a missing, malformed, unreadable, stale, captainless, recent, or future mirror"
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
  out=$(FM_CAPTAIN_HOLD_NOW=2026-11-27T07:30:00Z run_captain "$home" due) || fail "due failed early"
  case "$out" in *"t1 waits"*) ;; *) fail "due before ask + 1h did not report waiting: $out" ;; esac
  out=$(FM_CAPTAIN_HOLD_NOW=2026-11-27T08:05:00Z run_captain "$home" due) || fail "due failed at ask + 1h"
  case "$out" in *"t1 proceeds at 09:00 UTC"*) ;; *) fail "due at ask + 1h did not report proceeds at 09:00 UTC: $out" ;; esac
  out=$(FM_CAPTAIN_HOLD_NOW=$DUE_ISO run_captain "$home" due) || fail "due failed at ask + 2h"
  case "$out" in *"t1 due now"*) ;; *) fail "due at ask + 2h did not report due now: $out" ;; esac
  write_mirror "$home" "captain:$((ASK_EPOCH - 600))" "captain:$((DUE_EPOCH - 300))"
  out=$(FM_CAPTAIN_HOLD_NOW=$DUE_ISO run_captain "$home" due) || fail "due failed after a captain message"
  case "$out" in *"t1 waits for the captain"*) ;; *) fail "due after a recent captain message did not report waiting for the captain: $out" ;; esac
  [ "$(body_of "$home" t1)" = "$before" ] || fail "due changed the held task"
  run_captain "$home" open t1 || fail "due released the hold"
  [ ! -s "$home/night.log" ] || fail "due ran the night check"
  pass "due lists each default-bearing hold as waiting, proceeds at HH:MM, or due now, and changes nothing"
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
  printf '%s' "$json" | jq -e --arg rec "$RECOMMENDATION" --arg ask "$ASK_ISO" --arg applied "$DUE_ISO" '
      (.decided_by_default | length) == 1
      and .decided_by_default[0].id == "t1"
      and .decided_by_default[0].recommendation == $rec
      and .decided_by_default[0].asked_at == $ask
      and .decided_by_default[0].applied_at == $applied' > /dev/null \
    || fail "bearings did not list the defaulted decision with its recommendation and times: $(printf '%s' "$json" | jq -c '.decided_by_default')"
  pass "bearings lists decisions settled by default separately from captain answers"
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
  test_night_check_input_refusals \
  test_due_lists_without_changing_anything \
  test_bearings_shows_decided_by_default_separately
