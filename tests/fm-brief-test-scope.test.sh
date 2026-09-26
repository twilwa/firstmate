#!/usr/bin/env bash
# Public-interface tests for fm-brief.sh test-scope declarations and exclusions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-test-scope)
HOME_ROOT="$TMP_ROOT/home"
mkdir -p "$HOME_ROOT/data"

fail_unless_contains() {
  local text=$1 expected=$2 context=$3
  case "$text" in
    *"$expected"*) ;;
    *) fail "$context: expected '$expected' in generated brief" ;;
  esac
}

test_help_documents_default_and_scope_choices() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  fail_unless_contains "$help" '--tests <none|focused|safe-suite|full>' 'help'
  fail_unless_contains "$help" 'to none; firstmate must pass --tests full explicitly for upstream-bound work' 'help'
  pass 'fm-brief.sh help documents explicit upstream full-suite selection'
}

firstmate_minutes() {
  local ms
  ms=$("$@") || fail "fm-test-run.sh --estimate-ms failed: $*"
  printf '%s\n' "$(((ms + 59999) / 60000))"
}

test_public_scaffold_renders_default_and_explicit_scopes() {
  local id scope brief status out safe_minutes full_minutes
  safe_minutes=$(firstmate_minutes xargs "$ROOT/bin/fm-test-run.sh" --estimate-ms --all < "$ROOT/tests/safe-suite-exclusions.txt")
  full_minutes=$(firstmate_minutes "$ROOT/bin/fm-test-run.sh" --estimate-ms --all)

  id='brief-scope-default-ship'
  FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-brief.sh" "$id" sample --mode local-only >/dev/null 2>&1 \
    || fail 'ship brief with omitted --tests failed'
  brief="$HOME_ROOT/data/$id/brief.md"
  assert_present "$brief" 'default ship brief was not written'
  assert_grep 'Scope: none.' "$brief" 'ship default is not none'
  assert_grep 'Expected duration: 0 minutes.' "$brief" 'default scope duration is missing'
  assert_grep 'Permits: no local test runs; still write any regression test the task requires, and CI runs it.' "$brief" 'none scope omitted what it permits'

  id='brief-scope-default-scout'
  FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-brief.sh" "$id" sample --scout >/dev/null 2>&1 \
    || fail 'scout brief with omitted --tests failed'
  assert_grep 'Scope: none.' "$HOME_ROOT/data/$id/brief.md" 'scout default is not none'

  for scope in focused safe-suite full; do
    id="brief-scope-$scope"
    FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-brief.sh" "$id" sample --mode local-only --tests "$scope" >/dev/null 2>&1 \
      || fail "ship brief rejected --tests $scope"
    brief="$HOME_ROOT/data/$id/brief.md"
    assert_grep "Scope: $scope." "$brief" "--tests $scope was not rendered"
    assert_grep 'Expected duration:' "$brief" "--tests $scope omitted expected duration"
    case "$scope" in
      focused)
        assert_grep 'Permits: only the tests covering the behavior you touch; never the full local suite.' "$brief" 'focused scope omitted what it permits'
        assert_grep 'record your own estimate in your first status line before running anything' "$brief" 'focused scope omitted its estimate instruction'
        ;;
      safe-suite)
        assert_grep 'never the full local suite. If the target repo has no such manifest, say so in your first status line and run focused tests instead.' "$brief" 'safe-suite omitted its missing-manifest fallback'
        assert_grep "Expected duration: about $safe_minutes minutes run serially in the Firstmate repo" "$brief" 'safe-suite duration does not match the measured estimate'
        assert_grep 'any other repo has no measured figure, so record your own estimate in your first status line' "$brief" 'safe-suite omitted the other-repo estimate instruction'
        assert_grep 'xargs bin/fm-test-run.sh --all < tests/safe-suite-exclusions.txt' "$brief" 'safe-suite omitted its invocation'
        ;;
      full)
        assert_grep 'Permits: the full local suite' "$brief" 'full scope omitted what it permits'
        assert_grep "Expected duration: at least about $full_minutes minutes run serially in the Firstmate repo" "$brief" 'full duration does not match the measured floor'
        assert_grep 'not counting live Herdr, Codex, or Lavish runtime, which is unmeasured and can be much longer; record your own estimate in your first status line before starting.' "$brief" 'full duration does not disclaim unmeasured live runtime'
        ;;
    esac
  done

  id='brief-scope-scout-safe'
  FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-brief.sh" "$id" sample --scout --tests=safe-suite >/dev/null 2>&1 \
    || fail 'scout brief rejected --tests=safe-suite'
  assert_grep 'Scope: safe-suite.' "$HOME_ROOT/data/$id/brief.md" 'scout did not render its chosen test scope'

  out=$(FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-brief.sh" brief-scope-invalid sample --mode local-only --tests nope 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail 'invalid --tests value unexpectedly succeeded'
  fail_unless_contains "$out" '--tests must be one of none, focused, safe-suite, full' 'invalid scope refusal'
  assert_absent "$HOME_ROOT/data/brief-scope-invalid/brief.md" 'invalid scope left a partial brief'
  pass 'fm-brief.sh generates default and selected scopes through its public interface'
}

test_manifest_excludes_classified_and_live_gated_tests() {
  local manifest safe_list family_paths live_gated path family runtime
  manifest="$ROOT/tests/safe-suite-exclusions.txt"
  assert_present "$manifest" 'safe-suite exclusion manifest is missing'

  for family in real-herdr-gated live-harness-optin; do
    rg -F -x -q -- "--exclude-family $family" "$manifest" \
      || fail "safe-suite manifest does not exclude the $family family"
  done

  safe_list=$(xargs "$ROOT/bin/fm-test-run.sh" --list --all < "$manifest") \
    || fail 'safe-suite manifest could not be consumed by fm-test-run.sh'
  family_paths=$(
    "$ROOT/bin/fm-test-run.sh" --list --family real-herdr-gated
    "$ROOT/bin/fm-test-run.sh" --list --family live-harness-optin
  )
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if printf '%s\n' "$safe_list" | rg -F -x -q -- "$path"; then
      fail "safe-suite still includes a test from an excluded live family: $path"
    fi
  done <<EOF
$family_paths
EOF

  for runtime in herdr codex lavish-axi; do
    live_gated=$(rg -l -g '*.test.sh' \
      "^[[:space:]]*fm_live_gate[[:space:]].*[[:space:]]${runtime}([[:space:]]|$)" \
      "$ROOT/tests" || true)
    [ -n "$live_gated" ] || fail "no live-gated $runtime tests found for the safe-suite exclusion guard"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      case "$path" in
        "$ROOT"/*) path=${path#"$ROOT/"} ;;
      esac
      if printf '%s\n' "$safe_list" | rg -F -x -q -- "$path"; then
        fail "safe-suite includes a live $runtime test: $path"
      fi
    done <<EOF
$live_gated
EOF
  done
  pass 'safe-suite manifest excludes live Herdr, Codex, and Lavish families'
}

test_promotion_renders_selected_scope() {
  local id=promote-scope-full brief instructions status out
  FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-brief.sh" "$id" sample --scout >/dev/null 2>&1 \
    || fail 'scout brief for promotion failed'
  brief="$HOME_ROOT/data/$id/brief.md"
  sed -i.bak -e 's/{TASK}/Fix the widget./' -e 's/{FIRSTMATE_SPEC}/Inspect the widget./' "$brief"
  mkdir -p "$HOME_ROOT/state"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$HOME_ROOT/state/$id.meta"

  out=$(FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-promote.sh" "$id" --mode direct-PR --yolo off --tests nope 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail 'promotion accepted an invalid --tests value'
  fail_unless_contains "$out" '--tests must be one of none, focused, safe-suite, full' 'invalid promotion scope refusal'
  assert_grep 'kind=scout' "$HOME_ROOT/state/$id.meta" 'invalid promotion scope changed the task record'

  FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-promote.sh" "$id" --mode direct-PR --yolo off --tests full >/dev/null 2>&1 \
    || fail 'promotion with --tests full failed'
  instructions="$HOME_ROOT/data/$id/ship-instructions.md"
  assert_grep 'Scope: full.' "$instructions" 'promoted ship instructions omitted the selected scope'
  assert_grep 'Permits: the full local suite' "$instructions" 'promoted ship instructions omitted what full permits'
  assert_grep 'Expected duration: at least about' "$instructions" 'promoted ship instructions omitted the full-suite floor'
  assert_grep 'Scope: full.' "$brief" 'promoted brief omitted the selected scope for relaunch'
  pass 'fm-promote.sh renders the selected test scope into ship instructions and the promoted brief'
}

test_help_documents_default_and_scope_choices
test_public_scaffold_renders_default_and_explicit_scopes
test_promotion_renders_selected_scope
test_manifest_excludes_classified_and_live_gated_tests

printf 'All test-scope brief tests passed.\n'
