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

test_public_scaffold_renders_default_and_explicit_scopes() {
  local id scope brief status out

  id='brief-scope-default-ship'
  FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-brief.sh" "$id" sample --mode local-only >/dev/null 2>&1 \
    || fail 'ship brief with omitted --tests failed'
  brief="$HOME_ROOT/data/$id/brief.md"
  assert_present "$brief" 'default ship brief was not written'
  assert_grep 'Scope: none.' "$brief" 'ship default is not none'
  assert_grep 'Expected duration: 0 minutes.' "$brief" 'default scope duration is missing'

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
        assert_grep 'recent timings for the selected tests before running' "$brief" 'focused scope omitted its duration estimate instruction'
        ;;
      safe-suite)
        assert_grep 'recent safe-suite timings before running' "$brief" 'safe-suite omitted its duration estimate instruction'
        assert_grep 'tests/safe-suite-exclusions.txt' "$brief" 'safe-suite omitted the exclusion manifest'
        assert_grep 'xargs bin/fm-test-run.sh --all < tests/safe-suite-exclusions.txt' "$brief" 'safe-suite omitted its invocation'
        ;;
      full)
        assert_grep 'recent full-suite timings before running' "$brief" 'full scope omitted the full-suite duration guidance'
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

test_help_documents_default_and_scope_choices
test_public_scaffold_renders_default_and_explicit_scopes
test_manifest_excludes_classified_and_live_gated_tests

printf 'All test-scope brief tests passed.\n'
