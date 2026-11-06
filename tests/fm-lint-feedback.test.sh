#!/usr/bin/env bash
# Opt-in lint feedback through ship completion and generated worker instructions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lint-feedback)
fm_git_identity fmtest fmtest@example.invalid
HOME_FIXTURE="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/widget"
WT="$TMP_ROOT/worker"
mkdir -p "$HOME_FIXTURE/config" "$WT" "$PROJECT"
export FM_HOME="$HOME_FIXTURE"
git -C "$WT" init -q
git -C "$WT" commit -q --allow-empty -m initial
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" update-ref refs/remotes/origin/main "$HEAD_SHA"
printf '%s\n' '{"widget":{"command":"just lint-feedback --changed","receipt":".lint-feedback/receipt.json"}}' > "$HOME_FIXTURE/config/lint-feedback.json"

assert_receipt_refused() {
  local reason rc
  reason=$(fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready')
  rc=$?
  expect_code 1 "$rc" "ship completion must refuse $1 receipt"
  assert_contains "$reason" 'lint-feedback receipt' 'refusal must identify the receipt'
  assert_contains "$reason" "$1" 'refusal must identify the receipt problem'
}

test_missing_receipt_refuses() {
  assert_receipt_refused missing
  pass 'an opted-in ship cannot finish without its lint-feedback receipt'
}

test_malformed_receipt_refuses() {
  mkdir -p "$WT/.lint-feedback"
  printf '{broken json\n' > "$WT/.lint-feedback/receipt.json"
  assert_receipt_refused parse
  pass 'an invalid JSON receipt cannot authorize completion'
}

write_receipt() {
  mkdir -p "$WT/.lint-feedback"
  printf '%s\n' '{"schema":"lint-feedback/v1","dirty":false,"complete":true,"exit_status":0}' \
    | jq --arg head "$HEAD_SHA" ".head = \$head | ${1:-.}" > "$WT/.lint-feedback/receipt.json"
}

test_schema_refuses_and_valid_receipt_accepts() {
  local change reason rc
  for change in 'del(.schema)' '.schema = 1' '.schema = "other/v1"'; do
    write_receipt "$change"
    assert_receipt_refused schema
  done
  write_receipt
  fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready' || fail 'valid receipt was refused'
  git -C "$WT" update-ref -d refs/remotes/origin/main
  reason=$(fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready'); rc=$?
  expect_code 1 "$rc" 'valid receipt must not bypass named-head preservation'
  assert_contains "$reason" "named head $HEAD_SHA is unreachable outside the worker copy" 'existing reachability refusal must survive receipt acceptance'
  git -C "$WT" update-ref refs/remotes/origin/main "$HEAD_SHA"
  pass 'only a lint-feedback schema accepts the receipt without bypassing named-head preservation'
}

test_receipt_head_must_name_checked_commit() {
  local change
  for change in 'del(.head)' '.head = "0000000000000000000000000000000000000000"' '.head = "HEAD"'; do
    write_receipt "$change"
    touch "$WT/.lint-feedback/receipt.json"
    assert_receipt_refused head
  done
  write_receipt
  touch -t 200001010000 "$WT/.lint-feedback/receipt.json"
  fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready' || fail 'old mtime must not invalidate matching head'
  pass 'head identity, not receipt mtime, controls acceptance'
}

test_dirty_receipt_refuses() {
  local change
  for change in 'del(.dirty)' '.dirty = true' '.dirty = "false"'; do
    write_receipt "$change"
    assert_receipt_refused dirty
  done
  pass 'dirty must explicitly be false'
}

test_incomplete_receipt_refuses() {
  local change
  for change in 'del(.complete)' '.complete = false' '.complete = "true"'; do
    write_receipt "$change"
    assert_receipt_refused complete
  done
  pass 'complete must explicitly be true'
}

test_failing_receipt_refuses() {
  local change
  for change in 'del(.exit_status)' '.exit_status = 1' '.exit_status = 0.5' '.exit_status = "0"' '.exit_status = false'; do
    write_receipt "$change"
    assert_receipt_refused exit_status
  done
  pass 'exit_status must be the integer zero'
}

test_opt_in_only_ship_completion() {
  local reason rc
  rm -f "$WT/.lint-feedback/receipt.json"
  fm_dod_accept_ship_done ship direct-PR "$WT" "$TMP_ROOT/other-project" 'done: ready' || fail 'other projects must not require a receipt'
  fm_dod_accept_ship_done scout direct-PR "$WT" "$PROJECT" 'done: report' || fail 'scouts must not require a receipt'
  fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'working: editing' || fail 'only completion requires a receipt'
  reason=$(fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" 'done: implementation committed'); rc=$?
  expect_code 1 "$rc" 'opted-in pre-validation handoff requires a receipt'
  assert_contains "$reason" 'receipt missing' 'pre-validation refusal identifies missing receipt'
  write_receipt
  fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" 'done: implementation committed' || fail 'valid receipt permits pipeline handoff'
  mv "$HOME_FIXTURE/config/lint-feedback.json" "$HOME_FIXTURE/config/lint-feedback.disabled"
  rm -f "$WT/.lint-feedback/receipt.json"
  fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready' || fail 'absent config must retain prior acceptance'
  mv "$HOME_FIXTURE/config/lint-feedback.disabled" "$HOME_FIXTURE/config/lint-feedback.json"
  pass 'opt-in affects only ship completion, including the pipeline handoff'
}

test_ship_brief_includes_feedback_instructions() {
  local output brief
  output=$("$ROOT/bin/fm-brief.sh" lint-ship widget --mode direct-PR --tests focused --project "$PROJECT" 2>&1) || fail "$output"
  brief=$(cat "$HOME_FIXTURE/data/lint-ship/brief.md")
  assert_contains "$brief" 'just lint-feedback --changed' 'ship brief must name the configured command'
  assert_contains "$brief" '.lint-feedback/receipt.json' 'ship brief must name the receipt'
  assert_contains "$brief" 'after each coherent edit batch' 'ship brief must require frequent feedback'
  assert_contains "$brief" 'final commit before handoff' 'ship brief must require committed-head feedback'
  assert_contains "$brief" 'diagnostics' 'ship brief must require reading diagnostics'
  assert_contains "$brief" 'leave the receipt in place' 'ship brief must preserve the receipt'
  pass 'opted-in ship instructions require the lint-feedback command and receipt'
}

test_unaffected_briefs() {
  local output brief
  output=$("$ROOT/bin/fm-brief.sh" lint-scout widget --scout --tests focused 2>&1) || fail "$output"
  brief=$(cat "$HOME_FIXTURE/data/lint-scout/brief.md")
  assert_not_contains "$brief" 'Repository lint feedback' 'scout brief must not inject lint instructions'
  output=$("$ROOT/bin/fm-brief.sh" lint-other other-project --mode direct-PR --tests focused 2>&1) || fail "$output"
  brief=$(cat "$HOME_FIXTURE/data/lint-other/brief.md")
  assert_not_contains "$brief" 'Repository lint feedback' 'other project must not inject lint instructions'
  output=$("$ROOT/bin/fm-brief.sh" lint-by-name widget --mode local-only --tests focused 2>&1) || fail "$output"
  brief=$(cat "$HOME_FIXTURE/data/lint-by-name/brief.md")
  assert_contains "$brief" 'just lint-feedback --changed' 'repository name selects opt-in without --project'
  pass 'scouts and other projects are unchanged; ship repository name selects the declaration'
}

test_receipt_matches_forge_named_head() {
  local meta="$HOME_FIXTURE/forge.meta" reason rc forge_head=1111111111111111111111111111111111111111
  printf 'pr=https://github.com/example/widget/pull/4\npr_head=%s\n' "$forge_head" > "$meta"
  write_receipt
  reason=$(fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" 'done: PR https://github.com/example/widget/pull/4 checks green' '' task "$meta"); rc=$?
  expect_code 1 "$rc" 'receipt for worker HEAD cannot stand in for forge named head'
  assert_contains "$reason" "$forge_head" 'refusal identifies the forge named head'
  write_receipt ".head = \"$forge_head\""
  fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" 'done: PR https://github.com/example/widget/pull/4 checks green' '' task "$meta" || fail 'receipt for recorded forge head must pass'
  printf 'pr=https://github.com/example/widget/pull/4\npr_head=not-a-full-sha\n' > "$meta"
  write_receipt '.head = "not-a-full-sha"'
  reason=$(fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" 'done: PR https://github.com/example/widget/pull/4 checks green' '' task "$meta"); rc=$?
  expect_code 1 "$rc" 'matching malformed metadata cannot authorize a non-SHA receipt head'
  assert_contains "$reason" 'receipt head' 'refusal identifies malformed receipt head'
  pass 'recorded forge head, not an older worker HEAD, names the checked commit'
}

# Only these children see PATH stubs: none forwards to a real service or agent.
make_consumer_tools() {
  mkdir -p "$TMP_ROOT/fakebin" "$TMP_ROOT/root/bin" "$HOME_FIXTURE/state"
  cat > "$TMP_ROOT/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'lint\n' ;;
  display-message)
    case " $* " in
      *'#{pane_current_command}'*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
  *) exit 1 ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/fakebin/no-mistakes"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/root/bin/fm-guard.sh"
  cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' --json isDraft '*) printf '{"isDraft":false}\n' ;;
  *' --json headRefOid '*) printf '%s\n' "$FM_TEST_FORGE_HEAD" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$TMP_ROOT/fakebin/gh" "$TMP_ROOT/fakebin/tmux" "$TMP_ROOT/fakebin/no-mistakes" "$TMP_ROOT/root/bin/fm-guard.sh"
  head -n2 "$TMP_ROOT/fakebin/gh" "$TMP_ROOT/fakebin/tmux" "$TMP_ROOT/fakebin/no-mistakes" "$TMP_ROOT/root/bin/fm-guard.sh" >/dev/null
}

consumer() {
  local script=$1
  shift
  PATH="$TMP_ROOT/fakebin:$PATH" FM_ROOT_OVERRIDE="$TMP_ROOT/root" NM_HOME="$TMP_ROOT/no-mistakes-unused" FM_TEST_FORGE_HEAD="${FM_TEST_FORGE_HEAD:-$HEAD_SHA}" \
    "$ROOT/bin/$script" "$@"
}

write_consumer_meta() {
  printf 'kind=ship\nbackend=tmux\nwindow=fm-test:lint\nharness=claude\nmode=%s\nworktree=%s\nproject=%s\n' "$1" "$WT" "$PROJECT" > "$HOME_FIXTURE/state/lint.meta"
  chmod 600 "$HOME_FIXTURE/state/lint.meta"
}

test_pr_registration_requires_receipt_on_forge_head_path() {
  local output rc forge_head=1111111111111111111111111111111111111111
  make_consumer_tools
  write_consumer_meta no-mistakes
  rm -f "$WT/.lint-feedback/receipt.json"
  output=$(consumer fm-pr-check.sh lint https://github.com/example/widget/pull/4 2>&1); rc=$?
  expect_code 1 "$rc" 'live forge head cannot bypass missing receipt'
  assert_contains "$output" 'lint-feedback receipt missing' 'PR registration must name receipt problem'
  [ ! -f "$HOME_FIXTURE/state/lint.check.sh" ] || fail 'refused receipt must not register a PR poll'
  write_receipt
  output=$(FM_TEST_FORGE_HEAD=$forge_head consumer fm-pr-check.sh lint https://github.com/example/widget/pull/4 2>&1); rc=$?
  expect_code 1 "$rc" 'worker HEAD receipt cannot stand in for a different live forge head'
  assert_contains "$output" "$forge_head" 'live named head must be identified in the refusal'
  write_receipt ".head = \"$forge_head\""
  output=$(FM_TEST_FORGE_HEAD=$forge_head consumer fm-pr-check.sh lint https://github.com/example/widget/pull/4 2>&1) || fail "$output"
  assert_contains "$output" 'armed:' 'matching live forge head receipt permits PR registration'
  pass 'PR registration checks the receipt even when a live forge head proves preservation'
}

test_crew_state_requires_receipt() {
  local output change generation
  write_consumer_meta direct-PR
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_FIXTURE/state" lint) || fail 'could not arm fixture idle record'
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_FIXTURE/state" lint idle --gen "$generation" --source claude-hook --event stop || fail 'could not record fixture idle state'
  printf 'done: ready\n' > "$HOME_FIXTURE/state/lint.status"
  rm -f "$WT/.lint-feedback/receipt.json"
  output=$(consumer fm-crew-state.sh lint) || fail "$output"
  assert_contains "$output" 'state: blocked' 'missing receipt must refuse current-state completion'
  assert_contains "$output" 'lint-feedback receipt missing' 'current-state refusal identifies receipt'
  for change in '.head = "stale"' '.dirty = true' '.complete = false' '.exit_status = 1'; do
    write_receipt "$change"
    output=$(consumer fm-crew-state.sh lint) || fail "$output"
    assert_contains "$output" 'state: blocked' 'bad receipt must refuse current-state completion'
    assert_contains "$output" 'lint-feedback receipt' 'current-state refusal identifies receipt'
  done
  write_receipt
  output=$(consumer fm-crew-state.sh lint) || fail "$output"
  assert_contains "$output" 'state: done' 'valid receipt permits current-state completion'
  pass 'crew-state refuses invalid receipts and accepts a clean matching receipt'
}

test_invalid_declaration_refuses_without_partial_brief() {
  local config output rc index=0
  cp "$HOME_FIXTURE/config/lint-feedback.json" "$TMP_ROOT/good-config.json"
  for config in '{broken' '{"widget":null}' '{"widget":false}' \
    '{"widget":{"command":" ","receipt":"receipt.json"}}' \
    '{"widget":{"command":"just lint-feedback --changed","receipt":"../receipt.json"}}' \
    '{"widget":{"command":"just lint-feedback --changed","receipt":"/receipt.json"}}'; do
    index=$((index + 1))
    printf '%s\n' "$config" > "$HOME_FIXTURE/config/lint-feedback.json"
    output=$("$ROOT/bin/fm-brief.sh" "bad-lint-$index" widget --mode direct-PR --tests focused 2>&1); rc=$?
    expect_code 1 "$rc" 'invalid declaration must refuse brief generation'
    assert_contains "$output" 'invalid lint-feedback declaration' 'declaration error must be actionable'
    [ ! -f "$HOME_FIXTURE/data/bad-lint-$index/brief.md" ] || fail 'invalid declaration left a partial brief'
    output=$(fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready'); rc=$?
    expect_code 1 "$rc" 'invalid declaration cannot disable completion checks'
    assert_contains "$output" 'invalid lint-feedback declaration' 'completion must identify the configuration error'
  done
  cp "$TMP_ROOT/good-config.json" "$HOME_FIXTURE/config/lint-feedback.json"
  pass 'invalid configured opt-in refuses both briefing and completion'
}

fm_test_run \
  test_missing_receipt_refuses \
  test_malformed_receipt_refuses \
  test_schema_refuses_and_valid_receipt_accepts \
  test_receipt_head_must_name_checked_commit \
  test_dirty_receipt_refuses \
  test_incomplete_receipt_refuses \
  test_failing_receipt_refuses \
  test_opt_in_only_ship_completion \
  test_ship_brief_includes_feedback_instructions \
  test_unaffected_briefs \
  test_receipt_matches_forge_named_head \
  test_pr_registration_requires_receipt_on_forge_head_path \
  test_crew_state_requires_receipt \
  test_invalid_declaration_refuses_without_partial_brief
