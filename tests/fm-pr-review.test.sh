#!/usr/bin/env bash
# Behavioral coverage for the head-keyed PR review ledger and its silent gates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-pr-review.sh"
RISK="$ROOT/bin/fm-pr-risk.sh"
SNAPSHOTTER="$ROOT/bin/fm-pr-review-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-review-tests)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
URL=https://github.com/o/r/pull/7
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

snapshot() { # path head pending-json comments-json checks-json files-json
  jq -n --arg url "$URL" --arg head "$2" \
    --argjson pending "$3" --argjson comments "$4" --argjson checks "$5" --argjson files "$6" '{
      schema:"firstmate-pr-review-snapshot.v1",url:$url,head:$head,
      pending_reviews:$pending,comments:$comments,checks:$checks,files:$files
    }' > "$1"
}

review() {
  FM_HOME="$HOME_DIR" FM_REVIEW_NOW="${FM_TEST_NOW_ISO:-2026-09-20T00:00:00Z}" \
    FM_REVIEW_NOW_EPOCH="${FM_TEST_NOW_EPOCH:-1000}" "$REVIEW" "$@"
}

ledger() {
  printf '%s/data/pr-review-ledger/github--o--r--7.json\n' "$HOME_DIR"
}

GREEN='[{"name":"ci","state":"SUCCESS","bucket":"pass","status":"COMPLETED","conclusion":"pass","required":true,"url":"https://example.test/ci"}]'
LOW_FILES='[{"filename":"tests/widget.test.sh","status":"modified","additions":10,"deletions":2}]'
COMMENTS='[
  {"kind":"top-level","id":"10","url":"https://example.test/top","author":"sourcery","body":"consider the edge case","updated_at":"2026-09-20T00:10:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  {"kind":"review-submission","id":"11","url":"https://example.test/review","author":"codex","body":"one finding","updated_at":"2026-09-20T00:10:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  {"kind":"inline-thread","id":"THREAD_12","url":"https://example.test/thread","author":"sentry","body":"inline finding","updated_at":"2026-09-20T00:10:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","resolved":false}
]'

test_pending_review_retries_and_every_review_surface_needs_disposition() {
  local initial pending settled withdrawn out status=0 path
  initial="$TMP_ROOT/initial.json"; pending="$TMP_ROOT/pending.json"; settled="$TMP_ROOT/settled.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=1000 review init task-x "$URL" --snapshot "$initial" >/dev/null \
    || fail 'ledger initialization failed'

  snapshot "$pending" "$HEAD_A" '["check:codex"]' '[]' "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=1600 FM_TEST_NOW_ISO=2026-09-20T00:10:00Z \
    review checkpoint "$URL" --snapshot "$pending" >/dev/null || fail 'pending checkpoint failed'
  path=$(ledger)
  [ "$(jq -r '.generations[-1].next_checkpoint_epoch' "$path")" = 1900 ] \
    || fail 'first pending review did not schedule the configured bounded retry'
  FM_TEST_NOW_EPOCH=1899 review poll > "$TMP_ROOT/poll-before"
  [ ! -s "$TMP_ROOT/poll-before" ] || fail 'watcher checkpoint fired before its backoff elapsed'
  FM_TEST_NOW_EPOCH=1900 review poll > "$TMP_ROOT/poll-due"
  assert_contains "$(cat "$TMP_ROOT/poll-due")" "$URL" 'due checkpoint did not wake through the existing watcher check'
  review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'an explicitly pending review counted as approval'

  snapshot "$settled" "$HEAD_A" '[]' "$COMMENTS" "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=1900 FM_TEST_NOW_ISO=2026-09-20T00:15:00Z \
    review checkpoint "$URL" --snapshot "$settled" >/dev/null || fail 'settled checkpoint failed'
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'top-level, submitted, and inline review findings passed without dispositions'
  withdrawn="$TMP_ROOT/withdrawn.json"
  snapshot "$withdrawn" "$HEAD_A" '[]' '[]' "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=1901 review checkpoint "$URL" --snapshot "$withdrawn" >/dev/null \
    || fail 'withdrawn-comment checkpoint failed'
  [ "$(jq '.generations[-1].review_items | length' "$path")" -eq 3 ] \
    || fail 'review comments disappeared from the durable ledger when no longer returned by GitHub'
  [ "$(jq '[.generations[-1].review_items[] | select(.present == false)] | length' "$path")" -eq 3 ] \
    || fail 'review comments no longer returned by GitHub were not marked absent'
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a deleted reviewer comment escaped disposition'
  review disposition "$URL" "$HEAD_A" top-level 10 rejected 'not applicable: linked reproduction disproves it' >/dev/null
  review disposition "$URL" "$HEAD_A" review-submission 11 addressed 'fixed by commit deadbeef' >/dev/null
  review disposition "$URL" "$HEAD_A" inline-thread THREAD_12 addressed 'fixed and thread resolved' >/dev/null
  review final-disposition "$URL" "$HEAD_A" 'https://example.test/final-a' >/dev/null
  review ready "$URL" "$HEAD_A" >/dev/null || fail 'fully dispositioned review surfaces did not become ready'
  pass 'pending reviews retry, and top-level comments, submissions, and inline threads all require dispositions'
}

test_new_head_invalidates_old_checks_and_review_coverage() {
  local changed status=0 path
  changed="$TMP_ROOT/changed.json"
  snapshot "$changed" "$HEAD_B" '[]' '[]' "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=2000 FM_TEST_NOW_ISO=2026-09-20T00:20:00Z \
    review checkpoint "$URL" --snapshot "$changed" >/dev/null || fail 'new-head checkpoint failed'
  path=$(ledger)
  [ "$(jq '.generations | length' "$path")" -eq 2 ] || fail 'new head did not create a ledger generation'
  [ "$(jq '.generations[-1].review_items | length' "$path")" -eq 0 ] || fail 'prior review items leaked into the new generation'
  status=0; review ready "$URL" "$HEAD_B" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'green checks sampled before the new head review window satisfied the current head'
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a superseded head remained merge-ready'
  pass 'a new head invalidates prior checks and review coverage'
}

test_high_stakes_requires_exact_fable_and_independent_review() {
  local high_files initial checkpoint status=0 reason
  high_files='[{"filename":"bin/fm-teardown.sh","status":"modified","additions":5,"deletions":1}]'
  printf '%s\n' "$high_files" > "$TMP_ROOT/high-files.json"
  reason=$($RISK "$TMP_ROOT/high-files.json") || fail 'risk classifier failed'
  [ "$(printf '%s' "$reason" | jq -r .level)" = high ] || fail 'lifecycle surface was not high stakes'
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  initial="$TMP_ROOT/high-initial.json"; checkpoint="$TMP_ROOT/high-checkpoint.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' '[]' "$high_files"
  snapshot "$checkpoint" "$HEAD_A" '[]' '[]' '[]' "$high_files"
  FM_TEST_NOW_EPOCH=3000 review init task-high "$URL" --snapshot "$initial" >/dev/null
  FM_TEST_NOW_EPOCH=3600 review checkpoint "$URL" --snapshot "$checkpoint" >/dev/null
  review attest "$URL" "$HEAD_A" no-mistakes fable-5.0 'run old-model' >/dev/null
  review attest "$URL" "$HEAD_A" independent-agent-review codex 'review URL' >/dev/null
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'another model was silently substituted for Fable 5.1'
  review attest "$URL" "$HEAD_A" no-mistakes fable-5.1 'run exact-model' >/dev/null
  review final-disposition "$URL" "$HEAD_A" 'https://example.test/final-high' >/dev/null
  review ready "$URL" "$HEAD_A" >/dev/null || fail 'exact Fable 5.1 and an independent review did not satisfy the high-stakes gate without repository-required checks'
  pass 'high-stakes readiness requires exact Fable 5.1 plus an independent review and accepts an empty required-check set'
}

test_risk_classifier_resolves_incomplete_evidence_high() {
  local result
  printf '%s\n' '[{"filename":"src/widget.sh","status":"modified","additions":2}]' \
    > "$TMP_ROOT/incomplete-risk.json"
  result=$($RISK "$TMP_ROOT/incomplete-risk.json") || fail 'risk classifier rejected incomplete evidence instead of classifying it'
  [ "$(printf '%s' "$result" | jq -r .level)" = high ] \
    || fail 'incomplete changed-surface evidence did not resolve to high stakes'
  assert_contains "$(printf '%s' "$result" | jq -r .reason)" uncertain \
    'incomplete changed-surface classification did not state its uncertainty'
  pass 'the risk classifier resolves incomplete changed-surface evidence to high stakes with a reason'
}

test_merge_decision_records_only_the_live_reviewed_head() {
  local exact moved status=0 path
  exact="$TMP_ROOT/exact.json"; moved="$TMP_ROOT/moved.json"
  snapshot "$exact" "$HEAD_A" '[]' '[]' "$GREEN" '[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]'
  snapshot "$moved" "$HEAD_B" '[]' '[]' "$GREEN" '[{"filename":"tests/x.test.sh","status":"modified","additions":3,"deletions":0}]'
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=4000 review init task-merge "$URL" --snapshot "$exact" >/dev/null
  FM_TEST_NOW_EPOCH=4600 review checkpoint "$URL" --snapshot "$exact" >/dev/null
  review final-disposition "$URL" "$HEAD_A" 'https://example.test/final-merge' >/dev/null
  FM_TEST_NOW_EPOCH=4601 review merge-decision "$URL" --snapshot "$exact" >/dev/null \
    || fail 'exact-head merge decision was refused'
  path=$(ledger)
  [ "$(jq -r '.generations[-1].merge_decision.reviewed_head' "$path")" = "$HEAD_A" ] \
    || fail 'merge decision did not record the reviewed head'
  [ "$(jq -r '.generations[-1].merge_decision.verified_head' "$path")" = "$HEAD_A" ] \
    || fail 'merge decision did not record the immediately verified head'

  status=0
  FM_TEST_NOW_EPOCH=4700 review merge-decision "$URL" --snapshot "$moved" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a moved head retained the prior merge decision'
  [ "$(jq -r '.generations[-1].merge_decision' "$path")" = null ] \
    || fail 'the moved-head generation retained a merge decision from the old head'
  pass 'merge decisions bind the immediately verified head to the reviewed ledger generation'
}

test_live_collector_includes_submitted_reviews_and_inline_threads() {
  local fakebin out kinds
  fakebin=$(fm_fakebin "$TMP_ROOT/snapshot-fake")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "${1:-} ${2:-}" in
  "api /repos/o/r/pulls/7")
    printf '%s\n' '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"user":{"login":"author"},"requested_reviewers":[{"login":"codex"}],"requested_teams":[]}'
    ;;
  "api /repos/o/r/pulls/7/files?per_page=100")
    printf '%s\n' '[[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]]'
    ;;
  "api /repos/o/r/issues/7/comments?per_page=100")
    printf '%s\n' '[[{"id":10,"html_url":"https://example.test/top","user":{"login":"sourcery"},"body":"top","updated_at":"2026-09-20T00:10:00Z"}]]'
    ;;
  "api /repos/o/r/pulls/7/reviews?per_page=100")
    printf '%s\n' '[[{"id":11,"html_url":"https://example.test/review","user":{"login":"codex"},"body":"submitted","state":"COMMENTED","submitted_at":"2026-09-20T00:10:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]]'
    ;;
  "api graphql")
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"THREAD_12","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":12,"url":"https://example.test/thread","body":"inline","updatedAt":"2026-09-20T00:10:00Z","author":{"login":"sentry"},"commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}}]}}}}}'
    ;;
  "pr checks")
    printf '%s\n' '[{"name":"ci","state":"FAILURE","bucket":"fail","link":"https://example.test/ci"}]'
    exit 1
    ;;
  "pr view")
    case "$*" in
      *statusCheckRollup*)
        printf '%s\n' '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","statusCheckRollup":[{"__typename":"CheckRun","name":"codex","status":"IN_PROGRESS","conclusion":null}]}'
        ;;
      *) printf '%s\n' "$head" ;;
    esac
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
  chmod +x "$fakebin/gh"
  out="$TMP_ROOT/live-snapshot.json"
  PATH="$fakebin:$PATH" "$SNAPSHOTTER" "$URL" "$out" || fail 'live collector fixture failed'
  kinds=$(jq -r '.comments[].kind' "$out" | LC_ALL=C sort)
  assert_contains "$kinds" 'top-level' 'top-level comment was absent from the live snapshot'
  assert_contains "$kinds" 'review-submission' 'submitted review was missed by the live collector'
  assert_contains "$kinds" 'inline-thread' 'inline review thread was missed by the live collector'
  [ "$(jq '.pending_reviews | length' "$out")" -eq 2 ] \
    || fail 'requested reviewer and pending reviewer check were not both retained'
  [ "$(jq -r '.checks[0].conclusion' "$out")" = fail ] \
    || fail 'a nonzero checks verdict discarded the complete required-check result'
  pass 'live collection reads top-level comments, submitted reviews, inline threads, and pending reviewers'
}

test_migrated_assessment_rows_are_durable_fixtures() {
  local fixture count held nulls
  count=0; held=0; nulls=0
  for fixture in "$ROOT"/tests/fixtures/pr-review-ledger/*.json; do
    jq -e '.schema == "firstmate-pr-review-ledger.v1" and
      (.url | startswith("https://github.com/")) and
      (.current_head == .generations[-1].head)' "$fixture" >/dev/null \
      || fail "migrated assessment fixture is invalid: $fixture"
    count=$((count + 1))
    [ "$(jq -r '.generations[-1].merge_decision.decision' "$fixture")" != hold ] || held=$((held + 1))
    nulls=$((nulls + $(jq '[.generations[-1].review_items[] | select(.disposition == null)] | length' "$fixture")))
  done
  [ "$count" -eq 5 ] || fail 'the five initial assessments were not all migrated into fixtures'
  [ "$held" -eq 5 ] || fail 'an imported held PR lost its real hold decision and reason'
  [ "$nulls" -gt 0 ] || fail 'imported undispositioned findings were defaulted instead of staying null'
  pass 'five initial assessments remain durable fixtures with honest null dispositions and hold decisions'
}

test_human_hold_survives_head_change_until_evidenced_release() {
  local first changed path status=0
  first="$TMP_ROOT/hold-first.json"; changed="$TMP_ROOT/hold-changed.json"
  snapshot "$first" "$HEAD_A" '[]' '[]' "$GREEN" "$LOW_FILES"
  snapshot "$changed" "$HEAD_B" '[]' '[]' "$GREEN" "$LOW_FILES"
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=5000 review init task-hold "$URL" --snapshot "$first" >/dev/null
  review hold "$URL" "$HEAD_A" 'unresolved rights decision' >/dev/null
  FM_TEST_NOW_EPOCH=5100 review checkpoint "$URL" --snapshot "$changed" >/dev/null
  path=$(ledger)
  [ "$(jq -r '.generations[-1].merge_decision.decision' "$path")" = hold ] \
    || fail 'a human hold disappeared when the head changed'
  status=0; review ready "$URL" "$HEAD_B" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a current human hold did not block readiness'
  review release-hold "$URL" "$HEAD_B" 'https://example.test/rights-decision' >/dev/null
  [ "$(jq -r '.generations[-1].merge_decision' "$path")" = null ] \
    || fail 'an evidenced hold release did not clear the current hold'
  pass 'human holds survive head changes and require an evidenced release'
}

test_merge_forwards_guarded_options_to_the_merge_parser() {
  local fakebin initial rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT/merge-forward-fake")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "${1:-} ${2:-}" in
  "api /repos/o/r/pulls/7")
    printf '%s\n' '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"user":{"login":"author"},"requested_reviewers":[],"requested_teams":[]}'
    ;;
  "api /repos/o/r/pulls/7/files?per_page=100")
    printf '%s\n' '[[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]]'
    ;;
  "api /repos/o/r/issues/7/comments?per_page=100"|"api /repos/o/r/pulls/7/reviews?per_page=100")
    printf '%s\n' '[[]]'
    ;;
  "api graphql")
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
    ;;
  "pr checks")
    printf '%s\n' '[{"name":"ci","state":"SUCCESS","bucket":"pass","link":"https://example.test/ci"}]'
    ;;
  "pr view")
    case "$*" in
      *statusCheckRollup*)
        printf '%s\n' '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","statusCheckRollup":[]}'
        ;;
      *) printf '%s\n' "$head" ;;
    esac
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
  chmod +x "$fakebin/gh"

  initial="$TMP_ROOT/merge-forward-initial.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' "$GREEN" "$LOW_FILES"
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=7000 review init task-forward "$URL" --snapshot "$initial" >/dev/null
  FM_TEST_NOW_EPOCH=7600 review checkpoint "$URL" --snapshot "$initial" >/dev/null
  review final-disposition "$URL" "$HEAD_A" 'https://example.test/final-forward' >/dev/null

  set +e
  PATH="$fakebin:$PATH" FM_TEST_NOW_EPOCH=7601 \
    review merge task-forward "$URL" --attended-override=bad \
      > "$TMP_ROOT/merge-forward.stdout" 2> "$TMP_ROOT/merge-forward.stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" 'merge forwarding: guarded option parser should reject the invalid value'
  assert_grep 'error: --attended-override takes no value' "$TMP_ROOT/merge-forward.stderr" \
    'merge forwarding: the wrapper hid a guarded merge option behind the forge separator'
  pass 'the review wrapper forwards guarded merge options to fm-pr-merge before forge arguments'
}

test_arm_reuses_the_authenticated_watcher_check() {
  review arm > "$TMP_ROOT/arm.out" || fail 'review checkpoint check did not arm'
  assert_present "$HOME_DIR/state/review-policy.check.sh" \
    'arming did not publish the watcher check shim'
  assert_present "$HOME_DIR/state/review-policy.check-trust" \
    'arming did not register the watcher check through the trust facility'
  [ "$(stat -c '%a' "$HOME_DIR/state/review-policy.check.sh" 2>/dev/null \
      || stat -f '%Lp' "$HOME_DIR/state/review-policy.check.sh")" = 700 ] \
    || fail 'review checkpoint check did not use the required private executable mode'
  FM_HOME="$HOME_DIR" FM_REVIEW_NOW_EPOCH=7601 \
    "$HOME_DIR/state/review-policy.check.sh" > "$TMP_ROOT/armed-poll.out" \
    || fail 'the registered review checkpoint check was not executable'
  review disarm >/dev/null || fail 'review checkpoint check did not disarm'
  assert_absent "$HOME_DIR/state/review-policy.check.sh" \
    'disarming left the watcher check shim behind'
  assert_absent "$HOME_DIR/state/review-policy.check-trust" \
    'disarming left the watcher trust binding behind'
  pass 'review checkpoints reuse the authenticated watcher check without another monitor'
}

test_pending_review_retries_and_every_review_surface_needs_disposition
test_new_head_invalidates_old_checks_and_review_coverage
test_high_stakes_requires_exact_fable_and_independent_review
test_risk_classifier_resolves_incomplete_evidence_high
test_merge_decision_records_only_the_live_reviewed_head
test_live_collector_includes_submitted_reviews_and_inline_threads
test_migrated_assessment_rows_are_durable_fixtures
test_human_hold_survives_head_change_until_evidenced_release
test_merge_forwards_guarded_options_to_the_merge_parser
test_arm_reuses_the_authenticated_watcher_check
