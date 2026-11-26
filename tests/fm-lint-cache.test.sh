#!/usr/bin/env bash
# Behavior tests for bin/fm-lint.sh's per-root ShellCheck pass cache.
#
# A wrong cache key would replay a stale pass and hide a real finding, so these
# tests drive the public fm-lint.sh interface against a fixture repository and
# a ShellCheck stub that logs every root it is asked to analyze: a hit is a
# root the stub never saw, a miss is a root it saw again. They hold the cache
# contract owned by bin/fm-lint-cache-lib.sh: the key covers the root, its
# transitive source closure, the ShellCheck build, the exact flags, and the
# lint-definition files; only a recorded pass is ever replayed; local and
# hosted runs keep separate entries; a corrupt or unreadable cache lints every
# root; and the uncached audit run names any stale key it proves.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_lint_cache_bounds_supported: the bounded per-root envelope a local
# explicit-path run needs (a watchdog and an enforceable ulimit -v at the
# default 12 GiB cap); macOS rejects ulimit -v, so these cases skip there.
fm_lint_cache_bounds_supported() {
  ( ulimit -v 12582912 ) 2>/dev/null || return 1
  type -P perl >/dev/null 2>&1
}

# fm_lint_cache_fixture <tmp>: a fixture repository holding copies of the lint
# owner and its libraries, plus a ShellCheck stub under <tmp>/fakebin. The stub
# answers --version with the pinned version, appends each analyzed root to
# FM_TEST_SC_LOG, and reports a finding (exit 1) for a root whose content holds
# LINT-BAD or whose path is listed in FM_TEST_SC_FAIL_LIST, a file outside every
# cache key that models an input the key cannot see. A root listed in
# FM_TEST_SC_OOM_LIST exhausts memory under --external-sources and passes
# without it; a root listed in FM_TEST_SC_SLOW_LIST outlives any deadline.
fm_lint_cache_fixture() {
  local tmp=$1
  mkdir -p "$tmp/repo/bin" "$tmp/repo/tests" "$tmp/fakebin"
  cp "$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-timeout-lib.sh" "$tmp/repo/bin/"
  [ ! -f "$ROOT/bin/fm-lint-cache-lib.sh" ] || cp "$ROOT/bin/fm-lint-cache-lib.sh" "$tmp/repo/bin/"
  cat > "$tmp/fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
external=0
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  [ "$1" != --external-sources ] || external=1
  shift
done
[ "$#" -eq 0 ] || shift
target=$1
printf '%s\n' "$target" >> "$FM_TEST_SC_LOG"
fm_test_listed() { [ -n "$1" ] && grep -Fxq "$target" "$1" 2>/dev/null; }
if [ "$external" -eq 1 ] && fm_test_listed "${FM_TEST_SC_OOM_LIST:-}"; then
  printf 'shellcheck: Heap exhausted;\n' >&2
  exit 251
fi
if fm_test_listed "${FM_TEST_SC_SLOW_LIST:-}"; then
  exec sleep 30
fi
if grep -q LINT-BAD "$target" 2>/dev/null \
  || { [ -n "${FM_TEST_SC_FAIL_LIST:-}" ] && grep -Fxq "$target" "$FM_TEST_SC_FAIL_LIST" 2>/dev/null; }; then
  printf '\nIn %s line 1:\n^-- SC2154 (warning): stub finding.\n' "$target"
  exit 1
fi
exit 0
SH
  chmod +x "$tmp/fakebin/shellcheck"
  : > "$tmp/sc.log"
}

# fm_lint_cache_run <tmp> [fm-lint args...]: run the fixture's lint owner as a
# local run (or, with FM_TEST_HOSTED=1, under the hosted workflow contract)
# with the fixture cache, capturing combined output in LINT_OUT and
# the exit status in LINT_RC. Callers add environment with a prefix.
fm_lint_cache_run() {
  local tmp=$1
  shift
  local -a scope=(-u GITHUB_ACTIONS -u FM_LINT_REQUIRE_BOUNDS)
  [ "${FM_TEST_HOSTED:-0}" != 1 ] || scope=(GITHUB_ACTIONS=true FM_LINT_REQUIRE_BOUNDS=1)
  : > "$tmp/sc.log"
  LINT_RC=0
  LINT_OUT=$(env "${scope[@]}" PATH="$tmp/fakebin:$PATH" \
    FM_LINT_CACHE_DIR="${FM_TEST_CACHE_DIR:-$tmp/cache}" FM_TEST_SC_LOG="$tmp/sc.log" \
    "$tmp/repo/bin/fm-lint.sh" "$@" 2>&1) || LINT_RC=$?
}

# fm_lint_cache_linted <tmp> <root>...: true when the last run analyzed every
# named root.
fm_lint_cache_linted() {
  local log="$1/sc.log" root
  shift
  for root in "$@"; do
    grep -Fxq "$root" "$log" || return 1
  done
}

test_unchanged_root_hits_a_recorded_pass() {
  if ! fm_lint_cache_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): ${FUNCNAME[0]}"
    return
  fi
  local tmp
  tmp=$(fm_test_tmproot fm-lint-cache-hit)
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\necho ok\n' > "$tmp/repo/tests/a.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -eq 0 ] || fail "the cold run failed (exit $LINT_RC)"$'\n'"$LINT_OUT"
  fm_lint_cache_linted "$tmp" tests/a.sh || fail "the cold run did not lint the root"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "lint cache: hits=0 misses=1 stored=1" "the cold run did not report its miss and stored pass"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -eq 0 ] || fail "the warm run failed (exit $LINT_RC)"$'\n'"$LINT_OUT"
  ! fm_lint_cache_linted "$tmp" tests/a.sh || fail "an unchanged root was linted again instead of hitting its recorded pass"
  assert_contains "$LINT_OUT" "lint cache: hits=1 misses=0 stored=0" "the warm run did not report its hit"
  pass "an unchanged root replays its recorded pass and the run reports hits and misses"
}

# fm_lint_cache_warm <tmp> <root>...: lint once so each root records a pass.
fm_lint_cache_warm() {
  local tmp=$1
  shift
  fm_lint_cache_run "$tmp" "$@"
  [ "$LINT_RC" -eq 0 ] || fail "the warming run failed (exit $LINT_RC)"$'\n'"$LINT_OUT"
  fm_lint_cache_run "$tmp" "$@"
  [ ! -s "$tmp/sc.log" ] || fail "the warm cache did not hit every root"$'\n'"$(cat "$tmp/sc.log")"$'\n'"$LINT_OUT"
}

fm_lint_cache_skip_unbounded() {
  fm_lint_cache_bounds_supported && return 1
  pass "SKIP (host cannot enforce the bounded envelope): $1"
}

test_changed_root_misses() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp
  tmp=$(fm_test_tmproot fm-lint-cache-root)
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\necho one\n' > "$tmp/repo/tests/a.sh"
  printf '#!/usr/bin/env bash\necho two\n' > "$tmp/repo/tests/b.sh"
  fm_lint_cache_warm "$tmp" tests/a.sh tests/b.sh
  printf 'echo changed\n' >> "$tmp/repo/tests/a.sh"
  fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh
  fm_lint_cache_linted "$tmp" tests/a.sh || fail "an edited root replayed its old pass"$'\n'"$LINT_OUT"
  ! fm_lint_cache_linted "$tmp" tests/b.sh || fail "an untouched root missed"
  assert_contains "$LINT_OUT" "lint cache: hits=1 misses=1 stored=1" "the run misreported its hits and misses"
  pass "editing a root misses only that root"
}

test_sourced_file_two_levels_down_misses() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-closure)
  fm_lint_cache_fixture "$tmp"
  repo="$tmp/repo"
  mkdir -p "$repo/lib"
  cat > "$repo/tests/a.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=lib/one.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/one.sh"
SH
  cat > "$repo/lib/one.sh" <<'SH'
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR/../lib
. "$LIB_DIR/two.sh"
[ -r "$LIB_DIR/three.sh" ] && . "$LIB_DIR"/three.sh
SH
  printf 'two=1\n' > "$repo/lib/two.sh"
  printf '#!/usr/bin/env bash\necho unrelated\n' > "$repo/tests/b.sh"
  fm_lint_cache_warm "$tmp" tests/a.sh tests/b.sh
  printf 'two=2\n' > "$repo/lib/two.sh"
  fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh
  fm_lint_cache_linted "$tmp" tests/a.sh \
    || fail "a change two source levels down replayed the root's old pass"$'\n'"$LINT_OUT"
  ! fm_lint_cache_linted "$tmp" tests/b.sh || fail "a root outside the changed closure missed"
  fm_lint_cache_warm "$tmp" tests/a.sh
  printf 'three=1\n' > "$repo/lib/three.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  fm_lint_cache_linted "$tmp" tests/a.sh \
    || fail "creating a sourced file the root could not find before replayed its old pass"$'\n'"$LINT_OUT"
  pass "a change anywhere in a root's transitive source closure misses, two levels down included"
}

test_changed_shellcheck_build_misses() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp
  tmp=$(fm_test_tmproot fm-lint-cache-build)
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\necho ok\n' > "$tmp/repo/tests/a.sh"
  fm_lint_cache_warm "$tmp" tests/a.sh
  printf '# another build reporting the same pinned version\n' >> "$tmp/fakebin/shellcheck"
  fm_lint_cache_run "$tmp" tests/a.sh
  fm_lint_cache_linted "$tmp" tests/a.sh \
    || fail "a different ShellCheck build replayed a pass recorded by the old one"$'\n'"$LINT_OUT"
  pass "a changed ShellCheck build misses even under the same pinned version"
}

test_changed_flag_or_lint_definition_misses() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp
  tmp=$(fm_test_tmproot fm-lint-cache-flags)
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\necho ok\n' > "$tmp/repo/tests/a.sh"
  fm_lint_cache_warm "$tmp" tests/a.sh
  fm_lint_cache_run "$tmp" --fast tests/a.sh
  fm_lint_cache_linted "$tmp" tests/a.sh \
    || fail "a run with different ShellCheck flags replayed a pass recorded under other flags"$'\n'"$LINT_OUT"
  fm_lint_cache_warm "$tmp" tests/a.sh
  printf '# a lint-definition edit\n' >> "$tmp/repo/bin/fm-lint.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  fm_lint_cache_linted "$tmp" tests/a.sh \
    || fail "an edited lint definition replayed a pass recorded under the old one"$'\n'"$LINT_OUT"
  pass "a changed ShellCheck flag or lint-definition file misses"
}

test_failing_root_is_never_recorded_or_replayed() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp attempt
  tmp=$(fm_test_tmproot fm-lint-cache-failing)
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\n# LINT-BAD\necho bad\n' > "$tmp/repo/tests/bad.sh"
  for attempt in 1 2; do
    fm_lint_cache_run "$tmp" tests/bad.sh
    [ "$LINT_RC" -ne 0 ] || fail "run $attempt passed a root with findings"$'\n'"$LINT_OUT"
    fm_lint_cache_linted "$tmp" tests/bad.sh || fail "run $attempt replayed a failing root instead of linting it"
    assert_contains "$LINT_OUT" "stub finding" "run $attempt did not report the root's findings"
  done
  [ -z "$(find "$tmp/cache" -type f 2>/dev/null)" ] || fail "a failing root left a cache entry"
  pass "a root with findings is never recorded and never replayed"
}

test_unknown_verdict_is_never_recorded_or_replayed() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo attempt entries
  local -a roots=(tests/ok.sh tests/slow.sh tests/oom.sh)
  tmp=$(fm_test_tmproot fm-lint-cache-unknown)
  fm_lint_cache_fixture "$tmp"
  repo="$tmp/repo"
  printf '#!/usr/bin/env bash\necho ok\n' > "$repo/tests/ok.sh"
  printf '#!/usr/bin/env bash\necho slow\n' > "$repo/tests/slow.sh"
  printf '#!/usr/bin/env bash\necho oom\n' > "$repo/tests/oom.sh"
  printf 'tests/slow.sh\n' > "$tmp/slow-list"
  printf 'tests/oom.sh\n' > "$tmp/oom-list"
  if [ "$(id -u)" -ne 0 ]; then
    cat > "$repo/tests/hidden.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=tests/secret.sh
. "$(dirname "${BASH_SOURCE[0]}")/secret.sh"
SH
    printf 'secret=1\n' > "$repo/tests/secret.sh"
    chmod 000 "$repo/tests/secret.sh"
    roots+=(tests/hidden.sh)
  fi
  for attempt in 1 2; do
    FM_LINT_ROOT_SECONDS=2 FM_LINT_ROOT_GRACE=1 \
      FM_TEST_SC_SLOW_LIST="$tmp/slow-list" FM_TEST_SC_OOM_LIST="$tmp/oom-list" \
      fm_lint_cache_run "$tmp" "${roots[@]}"
    [ "$LINT_RC" -ne 0 ] || fail "run $attempt passed a root that timed out"$'\n'"$LINT_OUT"
    assert_contains "$LINT_OUT" "reason=timeout" "run $attempt did not end the slow root on its deadline"
    assert_contains "$LINT_OUT" "tests/oom.sh hit the memory ceiling with --external-sources" \
      "run $attempt did not take the memory fallback"
    fm_lint_cache_linted "$tmp" "${roots[@]:1}" \
      || fail "run $attempt replayed a root whose verdict was never a recorded pass"$'\n'"$(cat "$tmp/sc.log")"$'\n'"$LINT_OUT"
  done
  ! fm_lint_cache_linted "$tmp" tests/ok.sh || fail "the clean control root did not replay its recorded pass"
  [ "$(id -u)" -eq 0 ] || assert_contains "$LINT_OUT" "uncacheable=1" "the root with an unreadable source was not uncacheable"
  chmod 644 "$repo/tests/secret.sh" 2>/dev/null || true
  entries=$(find "$tmp/cache" -type f ! -name '.tmp.*' 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "$entries" -eq 1 ] || fail "expected only the control root's entry, found $entries"
  pass "a timeout, a memory-fallback pass, or an uncacheable root is never recorded and never replayed"
}

test_corrupt_or_unreadable_cache_lints_everything() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp entry
  tmp=$(fm_test_tmproot fm-lint-cache-corrupt)
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\necho one\n' > "$tmp/repo/tests/a.sh"
  printf '#!/usr/bin/env bash\necho two\n' > "$tmp/repo/tests/b.sh"
  fm_lint_cache_warm "$tmp" tests/a.sh tests/b.sh
  entry=$(find "$tmp/cache" -type f | LC_ALL=C sort | head -n1)
  sed -i.orig 's/^verdict pass$/verdict pass /' "$entry" && rm -f "$entry.orig"
  fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh
  [ "$LINT_RC" -eq 0 ] || fail "a corrupt entry failed the run instead of linting it"$'\n'"$LINT_OUT"
  fm_lint_cache_linted "$tmp" tests/a.sh tests/b.sh \
    || fail "a corrupt entry did not make the run lint every root"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "malformed entry" "the corrupt entry was not reported"
  fm_lint_cache_warm "$tmp" tests/a.sh tests/b.sh
  printf 'truncated' > "$entry"
  fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh
  fm_lint_cache_linted "$tmp" tests/a.sh tests/b.sh \
    || fail "a truncated entry did not make the run lint every root"$'\n'"$LINT_OUT"
  if [ "$(id -u)" -ne 0 ]; then
    fm_lint_cache_warm "$tmp" tests/a.sh tests/b.sh
    chmod 000 "$entry"
    fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh
    chmod 644 "$entry"
    fm_lint_cache_linted "$tmp" tests/a.sh tests/b.sh \
      || fail "an unreadable entry did not make the run lint every root"$'\n'"$LINT_OUT"
    fm_lint_cache_warm "$tmp" tests/a.sh tests/b.sh
    chmod 000 "$tmp/cache"
    fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh
    chmod 755 "$tmp/cache"
    fm_lint_cache_linted "$tmp" tests/a.sh tests/b.sh \
      || fail "an unreadable cache directory did not make the run lint every root"$'\n'"$LINT_OUT"
    assert_contains "$LINT_OUT" "is not a readable directory" "the unreadable cache was not reported"
  fi
  pass "a corrupt, truncated, or unreadable cache lints every root and never passes on it"
}

test_local_and_hosted_entries_do_not_collide() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp
  tmp=$(fm_test_tmproot fm-lint-cache-scope)
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\necho ok\n' > "$tmp/repo/tests/a.sh"
  fm_lint_cache_warm "$tmp" tests/a.sh
  FM_TEST_HOSTED=1 fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -eq 0 ] || fail "the hosted run failed (exit $LINT_RC)"$'\n'"$LINT_OUT"
  fm_lint_cache_linted "$tmp" tests/a.sh || fail "a hosted run replayed a pass recorded by a local run"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "scope=hosted" "the hosted run did not report its scope"
  FM_TEST_HOSTED=1 fm_lint_cache_run "$tmp" tests/a.sh
  ! fm_lint_cache_linted "$tmp" tests/a.sh || fail "a hosted run did not hit its own recorded pass"
  printf 'echo edit\n' >> "$tmp/repo/tests/a.sh"
  FM_TEST_HOSTED=1 fm_lint_cache_run "$tmp" tests/a.sh
  fm_lint_cache_run "$tmp" tests/a.sh
  fm_lint_cache_linted "$tmp" tests/a.sh || fail "a local run replayed a pass recorded by a hosted run"$'\n'"$LINT_OUT"
  pass "local and hosted runs keep separate entries"
}

test_uncached_audit_bypasses_the_cache_and_names_a_stale_key() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp key before after
  tmp=$(fm_test_tmproot fm-lint-cache-audit)
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\necho one\n' > "$tmp/repo/tests/a.sh"
  printf '#!/usr/bin/env bash\necho two\n' > "$tmp/repo/tests/b.sh"
  fm_lint_cache_warm "$tmp" tests/a.sh tests/b.sh
  # An input outside every key now makes a.sh fail: the cached run cannot see it.
  printf 'tests/a.sh\n' > "$tmp/fail-list"
  FM_TEST_SC_FAIL_LIST="$tmp/fail-list" fm_lint_cache_run "$tmp" --telemetry "$tmp/cached.tsv" tests/a.sh tests/b.sh
  [ "$LINT_RC" -eq 0 ] && [ ! -s "$tmp/sc.log" ] \
    || fail "the cached run did not replay both recorded passes"$'\n'"$LINT_OUT"
  key=$(awk -F '\t' '$1 == "root" && $2 == "tests/a.sh" && $3 == "hit" { print $4 }' "$tmp/cached.cache.tsv")
  [ -n "$key" ] || fail "the cached run's sidecar did not record the hit's key"$'\n'"$(cat "$tmp/cached.cache.tsv" 2>&1)"
  before=$(find "$tmp/cache" -type f -exec cksum {} + | LC_ALL=C sort)
  FM_TEST_SC_FAIL_LIST="$tmp/fail-list" fm_lint_cache_run "$tmp" \
    --audit-cache "$tmp/cache" --audit-record "$tmp/cached.cache.tsv" tests/a.sh tests/b.sh
  fm_lint_cache_linted "$tmp" tests/a.sh tests/b.sh \
    || fail "the uncached audit run did not lint every root"$'\n'"$LINT_OUT"
  [ "$LINT_RC" -eq 3 ] || fail "the audit run did not fail with the stale-key status 3 (exit $LINT_RC)"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "STALE LINT CACHE KEY $key: tests/a.sh has findings in this uncached run, but the cache at $tmp/cache recorded a pass" \
    "the audit did not name the stale key the cache recorded"
  assert_contains "$LINT_OUT" "STALE LINT CACHE KEY $key: tests/a.sh has findings in this uncached run, but the cached run's sidecar" \
    "the audit did not name the stale key the cached run replayed"
  assert_not_contains "$LINT_OUT" "tests/b.sh has findings" "the audit blamed a clean root"
  after=$(find "$tmp/cache" -type f -exec cksum {} + | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "the uncached audit run wrote to the cache"
  pass "the uncached audit run ignores the cache and fails naming the stale key a cached pass hid"
}

test_real_shellcheck_finding_two_levels_down_is_not_hidden() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local sc tmp repo
  if ! sc=$(type -P shellcheck) || [ "$("$sc" --version | awk '/^version:/ {print $2; exit}')" != "$("$ROOT/bin/fm-lint.sh" --required-version)" ]; then
    pass "SKIP (pinned ShellCheck not resolved): ${FUNCNAME[0]}"
    return
  fi
  tmp=$(fm_test_tmproot fm-lint-cache-real)
  fm_lint_cache_fixture "$tmp"
  ln -sf "$sc" "$tmp/fakebin/shellcheck"
  repo="$tmp/repo"
  cat > "$repo/tests/a.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=tests/one.sh
. "$(dirname "${BASH_SOURCE[0]}")/one.sh"
printf '%s\n' "$from_two"
SH
  cat > "$repo/tests/one.sh" <<'SH'
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
. "$HERE/two.sh"
SH
  printf '# shellcheck shell=bash\nexport from_two=1\n' > "$repo/tests/two.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -eq 0 ] || fail "the clean fixture did not pass real ShellCheck"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "stored=1" "the clean fixture's pass was not recorded"
  printf '# shellcheck shell=bash\n' > "$repo/tests/two.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -ne 0 ] || fail "a recorded pass hid a real finding introduced two source levels down"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "SC2154" "real ShellCheck did not report the unassigned variable"
  pass "real ShellCheck's finding from a file two source levels down is never hidden by a recorded pass"
}

fm_test_run \
  test_unchanged_root_hits_a_recorded_pass \
  test_changed_root_misses \
  test_sourced_file_two_levels_down_misses \
  test_changed_shellcheck_build_misses \
  test_changed_flag_or_lint_definition_misses \
  test_failing_root_is_never_recorded_or_replayed \
  test_unknown_verdict_is_never_recorded_or_replayed \
  test_corrupt_or_unreadable_cache_lints_everything \
  test_local_and_hosted_entries_do_not_collide \
  test_uncached_audit_bypasses_the_cache_and_names_a_stale_key \
  test_real_shellcheck_finding_two_levels_down_is_not_hidden
