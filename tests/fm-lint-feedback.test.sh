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
printf 'initial\n' > "$WT/tracked.txt"
printf '.lint-feedback/\n' > "$WT/.git/info/exclude"
git -C "$WT" add tracked.txt
git -C "$WT" commit -q -m initial
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" update-ref refs/remotes/origin/main "$HEAD_SHA"
printf '%s\n' '["widget"]' > "$HOME_FIXTURE/config/lint-feedback.json"

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

test_receipt_size_is_bounded_before_parsing() {
  local bytes
  write_receipt
  bytes=$(LC_ALL=C wc -c < "$WT/.lint-feedback/receipt.json")
  printf '%*s' "$((1048576 - bytes))" '' >> "$WT/.lint-feedback/receipt.json"
  fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready' \
    || fail 'a valid receipt exactly at the 1 MiB limit must be accepted'
  printf ' ' >> "$WT/.lint-feedback/receipt.json"
  assert_receipt_refused 'exceeds 1048576-byte limit'
  printf 'invalid JSON' >> "$WT/.lint-feedback/receipt.json"
  assert_receipt_refused 'exceeds 1048576-byte limit'
  pass 'receipt parsing accepts at most 1 MiB and refuses larger files before JSON parsing'
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

test_live_head_must_still_match_receipt() {
  local reason rc
  write_receipt
  printf 'new source\n' > "$WT/untracked.txt"
  fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" 'done: implementation committed' \
    || fail 'uncommitted files outside the named head must not refuse a matching receipt'
  rm "$WT/untracked.txt"
  printf 'new commit\n' >> "$WT/tracked.txt"
  git -C "$WT" add tracked.txt
  git -C "$WT" commit -q -m 'later fixture commit'
  reason=$(fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" 'done: implementation committed'); rc=$?
  expect_code 1 "$rc" 'a later live HEAD must invalidate the old handoff receipt'
  assert_contains "$reason" 'receipt head does not match named head' 'receipt must identify the live HEAD mismatch'
  HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
  git -C "$WT" update-ref refs/remotes/origin/main "$HEAD_SHA"
  write_receipt
  fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready' || fail 'new matching head must be accepted'
  pass 'a later live HEAD invalidates the handoff receipt; uncommitted files do not'
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

test_missing_jq_is_a_dependency_error() {
  local tool output rc no_jq_bin="$TMP_ROOT/no-jq-bin"
  mkdir -p "$no_jq_bin"
  for tool in bash git dirname sed grep head tail cut date tr mkdir basename wc sort uname cat readlink; do
    ln -s "$(type -P "$tool")" "$no_jq_bin/$tool"
  done
  write_receipt
  output=$(PATH="$no_jq_bin" "$ROOT/bin/fm-brief.sh" lint-no-jq widget --mode direct-PR --tests focused 2>&1); rc=$?
  expect_code 1 "$rc" 'missing jq must refuse opt-in brief generation'
  assert_contains "$output" 'missing dependency: jq' 'brief must identify the missing JSON tool'
  assert_not_contains "$output" 'invalid lint-feedback opt-in list' 'missing jq is not malformed configuration'
  [ ! -f "$HOME_FIXTURE/data/lint-no-jq/brief.md" ] || fail 'missing jq left a partial brief'
  output=$(PATH="$no_jq_bin" fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready'); rc=$?
  expect_code 1 "$rc" 'missing jq must refuse opted-in completion'
  assert_contains "$output" 'missing dependency: jq' 'completion must identify the missing JSON tool'
  assert_not_contains "$output" 'parse error' 'missing jq is not a malformed receipt'
  mv "$HOME_FIXTURE/config/lint-feedback.json" "$HOME_FIXTURE/config/lint-feedback.disabled"
  output=$(PATH="$no_jq_bin" fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" 'done: implementation committed'); rc=$?
  mv "$HOME_FIXTURE/config/lint-feedback.disabled" "$HOME_FIXTURE/config/lint-feedback.json"
  expect_code 0 "$rc" 'absent opt-in config must not add a jq dependency'
  pass 'missing jq is a distinct dependency refusal only when lint feedback is configured'
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
  assert_contains "$brief" 'just lint-feedback --changed' 'ship brief must name the lint-feedback command'
  assert_contains "$brief" '.lint-feedback/receipt.json' 'ship brief must name the receipt'
  assert_contains "$brief" 'after each coherent edit batch' 'ship brief must require frequent feedback'
  assert_contains "$brief" 'final commit before handoff' 'ship brief must require committed-head feedback'
  assert_contains "$brief" "The required command is \`just lint-feedback --changed\`" 'command must be a neutral requirement, not an imperative'
  assert_contains "$brief" 'Diagnostics must be read' 'diagnostic handling must be a neutral requirement'
  assert_contains "$brief" 'receipt must remain in place' 'ship brief must preserve the receipt'
  assert_not_contains "$brief" "Run \`just lint-feedback --changed\`" 'lint-feedback section must not order command execution imperatively'
  assert_not_contains "$brief" 'rerun after committing any fixes' 'rerun condition must be a neutral requirement'
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
  pass 'scouts and other projects are unchanged; ship repository name selects the opt-in'
}

test_brief_project_identity_and_missing_repository() {
  local output brief relative index=0 rc
  output=$("$ROOT/bin/fm-brief.sh" lint-missing-repo --mode direct-PR --tests focused 2>&1); rc=$?
  expect_code 1 "$rc" 'missing repository must refuse the scaffold'
  assert_contains "$output" 'repository name' 'missing repository must have an actionable argument error'
  assert_not_contains "$output" 'unbound variable' 'missing repository must not expand an unset positional element'
  [ ! -f "$HOME_FIXTURE/data/lint-missing-repo/brief.md" ] || fail 'missing repository left a partial brief'
  for relative in . ../widget "$PROJECT/."; do
    index=$((index + 1))
    output=$(CDPATH='' cd -- "$PROJECT" && "$ROOT/bin/fm-brief.sh" "lint-relative-$index" repository-alias --mode direct-PR --tests focused --project "$relative" 2>&1) || fail "$output"
    brief=$(cat "$HOME_FIXTURE/data/lint-relative-$index/brief.md")
    assert_contains "$brief" 'just lint-feedback --changed' 'resolved directory basename, not repository argument or dot, must select the opt-in'
  done
  pass 'briefs resolve relative project directory identity and reject missing repository arguments before writing'
}

test_symlinked_project_alias_keeps_logical_identity() {
  local alias output brief reason rc
  mkdir -p "$TMP_ROOT/checkouts/widget-main" "$TMP_ROOT/projects"
  alias="$TMP_ROOT/projects/widget"
  ln -s "$TMP_ROOT/checkouts/widget-main" "$alias"
  output=$("$ROOT/bin/fm-brief.sh" lint-alias widget --mode direct-PR --tests focused --project "$alias" 2>&1) || fail "$output"
  brief=$(cat "$HOME_FIXTURE/data/lint-alias/brief.md")
  assert_contains "$brief" 'just lint-feedback --changed' 'a symlinked project alias must select the opt-in by its own basename'
  rm -f "$WT/.lint-feedback/receipt.json"
  reason=$(fm_dod_accept_ship_done ship direct-PR "$WT" "$alias" 'done: ready'); rc=$?
  expect_code 1 "$rc" 'completion through a symlinked project alias must still require the receipt'
  assert_contains "$reason" 'lint-feedback receipt missing' 'completion must use the same alias basename as the brief'
  write_receipt
  fm_dod_accept_ship_done ship direct-PR "$WT" "$alias" 'done: ready' || fail 'a valid receipt must satisfy completion through the alias'
  pass 'a symlinked project alias has the same opt-in identity in the brief and at completion'
}

test_promoted_scout_includes_feedback_instructions() {
  local output instructions brief
  mkdir -p "$HOME_FIXTURE/state"
  output=$("$ROOT/bin/fm-brief.sh" lint-promote widget --scout --tests focused 2>&1) || fail "$output"
  sed -i.bak -e 's/{TASK}/Fix the widget./' -e 's/{FIRSTMATE_SPEC}/Inspect the widget./' \
    "$HOME_FIXTURE/data/lint-promote/brief.md"
  printf 'window=fm-lint-promote\nkind=scout\nworktree=%s\nproject=../widget/.\n' "$WT" > "$HOME_FIXTURE/state/lint-promote.meta"
  output=$(CDPATH='' cd -- "$PROJECT" && "$ROOT/bin/fm-promote.sh" lint-promote --mode direct-PR --yolo off 2>&1) || fail "$output"
  instructions=$(cat "$HOME_FIXTURE/data/lint-promote/ship-instructions.md")
  brief=$(cat "$HOME_FIXTURE/data/lint-promote/brief.md")
  assert_contains "$instructions" 'just lint-feedback --changed' 'promoted ship instructions must name the lint-feedback command'
  assert_contains "$instructions" '.lint-feedback/receipt.json' 'promoted ship instructions must name the receipt'
  assert_contains "$instructions" "The required command is \`just lint-feedback --changed\`" 'promotion must render the same neutral command requirement'
  assert_contains "$brief" 'just lint-feedback --changed' 'promoted brief must keep the lint-feedback command for a relaunch'
  pass 'a scout promoted on an opted-in project is told to run lint feedback and keep its receipt'
}

test_pipeline_moved_head_does_not_recheck_receipt() {
  local meta="$HOME_FIXTURE/forge.meta" forge_head=1111111111111111111111111111111111111111 line
  line='done: PR https://github.com/example/widget/pull/4 checks green'
  write_receipt
  fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" 'done: implementation committed' \
    || fail 'receipt for the worker handoff head must permit the pipeline handoff'
  printf 'pr=https://github.com/example/widget/pull/4\npr_head=%s\n' "$forge_head" > "$meta"
  printf 'later pipeline residue\n' > "$WT/pipeline-residue.txt"
  fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" "$line" '' task "$meta" \
    || fail 'pipeline commits on the forge head must not refuse the CI-ready done'
  rm -f "$WT/.lint-feedback/receipt.json"
  fm_dod_accept_ship_done ship no-mistakes "$WT" "$PROJECT" "$line" '' task "$meta" \
    || fail 'the CI-ready done is not re-checked against the receipt'
  rm "$WT/pipeline-residue.txt"
  pass 'the receipt binds to the worker handoff head, not a pipeline-moved forge head'
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

test_pr_registration_receipt_follows_worker_head() {
  local output rc forge_head=1111111111111111111111111111111111111111
  make_consumer_tools
  write_consumer_meta direct-PR
  rm -f "$WT/.lint-feedback/receipt.json"
  output=$(consumer fm-pr-check.sh lint https://github.com/example/widget/pull/4 2>&1); rc=$?
  expect_code 1 "$rc" 'direct-PR registration cannot bypass a missing receipt'
  assert_contains "$output" 'lint-feedback receipt missing' 'PR registration must name receipt problem'
  [ ! -f "$HOME_FIXTURE/state/lint.check.sh" ] || fail 'refused receipt must not register a PR poll'
  write_consumer_meta no-mistakes
  write_receipt
  printf 'later pipeline residue\n' > "$WT/pipeline-residue.txt"
  output=$(FM_TEST_FORGE_HEAD=$forge_head consumer fm-pr-check.sh lint https://github.com/example/widget/pull/4 2>&1) \
    || fail "pipeline-moved forge head refused PR registration: $output"
  assert_contains "$output" 'armed:' 'a live forge head moved by the pipeline permits PR registration'
  rm "$WT/pipeline-residue.txt"
  pass 'PR registration checks the worker-head receipt and skips it once the forge holds the pipeline head'
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

test_invalid_opt_in_list_refuses_without_partial_brief() {
  local config output rc index=0
  cp "$HOME_FIXTURE/config/lint-feedback.json" "$TMP_ROOT/good-config.json"
  for config in '{broken' '{"widget":{}}' '"widget"' '["widget",1]'; do
    index=$((index + 1))
    printf '%s\n' "$config" > "$HOME_FIXTURE/config/lint-feedback.json"
    output=$("$ROOT/bin/fm-brief.sh" "bad-lint-$index" widget --mode direct-PR --tests focused 2>&1); rc=$?
    expect_code 1 "$rc" 'invalid opt-in list must refuse brief generation'
    assert_contains "$output" 'invalid lint-feedback opt-in list' 'opt-in list error must be actionable'
    [ ! -f "$HOME_FIXTURE/data/bad-lint-$index/brief.md" ] || fail 'invalid opt-in list left a partial brief'
    output=$(fm_dod_accept_ship_done ship direct-PR "$WT" "$PROJECT" 'done: ready'); rc=$?
    expect_code 1 "$rc" 'invalid opt-in list cannot disable completion checks'
    assert_contains "$output" 'invalid lint-feedback opt-in list' 'completion must identify the configuration error'
  done
  cp "$TMP_ROOT/good-config.json" "$HOME_FIXTURE/config/lint-feedback.json"
  pass 'an invalid opt-in list refuses both briefing and completion'
}

fm_test_run \
  test_missing_receipt_refuses \
  test_malformed_receipt_refuses \
  test_receipt_size_is_bounded_before_parsing \
  test_schema_refuses_and_valid_receipt_accepts \
  test_receipt_head_must_name_checked_commit \
  test_live_head_must_still_match_receipt \
  test_dirty_receipt_refuses \
  test_incomplete_receipt_refuses \
  test_failing_receipt_refuses \
  test_missing_jq_is_a_dependency_error \
  test_opt_in_only_ship_completion \
  test_ship_brief_includes_feedback_instructions \
  test_unaffected_briefs \
  test_brief_project_identity_and_missing_repository \
  test_symlinked_project_alias_keeps_logical_identity \
  test_promoted_scout_includes_feedback_instructions \
  test_pipeline_moved_head_does_not_recheck_receipt \
  test_pr_registration_receipt_follows_worker_head \
  test_crew_state_requires_receipt \
  test_invalid_opt_in_list_refuses_without_partial_brief
