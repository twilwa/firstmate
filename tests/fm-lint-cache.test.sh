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
# default 12 GiB cap) plus a C compiler for the stub launcher below; macOS
# rejects ulimit -v, so these cases skip there.
fm_lint_cache_bounds_supported() {
  ( ulimit -v 12582912 ) 2>/dev/null || return 1
  type -P perl >/dev/null 2>&1 || return 1
  type -P cc >/dev/null 2>&1
}

# The cache only trusts a ShellCheck that is a regular executable, never a
# script wrapper, so the stub is a compiled launcher that hands its arguments
# to the bash script named by FM_TEST_SC_SCRIPT. Each build string yields a
# different binary, standing in for a different ShellCheck build.
FM_LINT_CACHE_LAUNCHERS=
fm_lint_cache_launcher() {  # <build> -> path of the compiled launcher
  local build=$1 out
  [ -n "$FM_LINT_CACHE_LAUNCHERS" ] || FM_LINT_CACHE_LAUNCHERS=$(fm_test_tmproot fm-lint-cache-launchers)
  out="$FM_LINT_CACHE_LAUNCHERS/shellcheck-$build"
  if [ ! -x "$out" ]; then
    cat > "$FM_LINT_CACHE_LAUNCHERS/launcher.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static const char build[] = "fm-lint-cache test launcher build " BUILD;
int main(int argc, char **argv) {
  const char *script = getenv("FM_TEST_SC_SCRIPT");
  char **args = calloc((size_t)argc + 2, sizeof *args);
  int i;
  if (script == NULL || args == NULL) {
    fprintf(stderr, "%s: FM_TEST_SC_SCRIPT is unset\n", build);
    return 2;
  }
  args[0] = "bash";
  args[1] = (char *)script;
  for (i = 1; i < argc; i++) args[i + 1] = argv[i];
  execv("/bin/bash", args);
  perror(build);
  return 127;
}
C
    cc -DBUILD="\"$build\"" -o "$out" "$FM_LINT_CACHE_LAUNCHERS/launcher.c" \
      || fail "could not compile the ShellCheck stub launcher"
  fi
  printf '%s\n' "$out"
}

# fm_lint_cache_fixture <tmp>: a fixture repository holding copies of the lint
# owner and its libraries, plus a ShellCheck stub: the compiled launcher at
# <tmp>/fakebin/shellcheck running the script <tmp>/stub.sh. The stub
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
  cp "$(fm_lint_cache_launcher 1)" "$tmp/fakebin/shellcheck"
  fm_lint_cache_trust "$tmp" "$tmp/fakebin/shellcheck"
  cat > "$tmp/stub.sh" <<'SH'
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
  : > "$tmp/sc.log"
}

# fm_lint_cache_trust <tmp> <executable>: the test-only fixture verifier. The
# cache trusts only the pinned ShellCheck release digests; a fixture extends
# its own copy of the library's allowlist with a stub launcher's digest.
fm_lint_cache_trust() {
  printf 'FM_LINT_CACHE_TRUSTED_SHELLCHECK_SHA256+=(%s)\n' \
    "$(perl -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile($ARGV[0])->hexdigest' "$2")" \
    >> "$1/repo/bin/fm-lint-cache-lib.sh"
}

# fm_lint_cache_run <tmp> [fm-lint args...]: run the fixture's lint owner as a
# local run (or, with FM_TEST_HOSTED=1, under the hosted workflow contract)
# with the fixture cache, capturing combined output in LINT_OUT and
# the exit status in LINT_RC. Callers add environment with a prefix;
# FM_TEST_TIMEOUT=<seconds> bounds the run (exit 124 when it hangs).
fm_lint_cache_run() {
  local tmp=$1
  shift
  local -a scope=(-u GITHUB_ACTIONS -u FM_LINT_REQUIRE_BOUNDS) guard=()
  [ "${FM_TEST_HOSTED:-0}" != 1 ] || scope=(GITHUB_ACTIONS=true FM_LINT_REQUIRE_BOUNDS=1)
  [ -z "${FM_TEST_TIMEOUT:-}" ] || guard=(timeout "$FM_TEST_TIMEOUT")
  : > "$tmp/sc.log"
  LINT_RC=0
  LINT_OUT=$(${guard[@]+"${guard[@]}"} env "${scope[@]}" PATH="$tmp/fakebin:$PATH" \
    FM_LINT_CACHE_DIR="${FM_TEST_CACHE_DIR-$tmp/cache}" FM_TEST_SC_LOG="$tmp/sc.log" \
    FM_TEST_SC_SCRIPT="$tmp/stub.sh" \
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
# shellcheck source=lib/two.sh
. "$LIB_DIR/two.sh"
# shellcheck source=lib/three.sh
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
  cp "$(fm_lint_cache_launcher 2)" "$tmp/fakebin/shellcheck"
  fm_lint_cache_trust "$tmp" "$tmp/fakebin/shellcheck"
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
    FM_LINT_ROOT_SECONDS=3 FM_LINT_ROOT_GRACE=1 \
      FM_TEST_SC_SLOW_LIST="$tmp/slow-list" FM_TEST_SC_OOM_LIST="$tmp/oom-list" \
      fm_lint_cache_run "$tmp" "${roots[@]}"
    [ "$LINT_RC" -ne 0 ] || fail "run $attempt passed a root that timed out"$'\n'"$LINT_OUT"
    assert_contains "$LINT_OUT" "reason=timeout" "run $attempt did not end the slow root on its deadline"
    assert_contains "$LINT_OUT" "tests/oom.sh hit the memory ceiling with --external-sources (reason=memory rc=251); retried without it; fallback passed with cross-file codes excluded" \
      "run $attempt did not pass the root through the memory fallback"
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

# fm_lint_cache_real_fixture <tmp> <test-name>: a fixture whose shellcheck is
# the real pinned ShellCheck; passes a SKIP and returns 1 when it is absent.
# The static binaries inside the official ShellCheck v0.11.0 linux release
# archives (shellcheck-v0.11.0.linux.{x86_64,aarch64}.tar.xz), computed from the
# archives whose published digests bin/fm-install-shellcheck.sh pins.
FM_LINT_CACHE_RELEASE_BINARIES='4da528ddb3a4d1b7b24a59d4e16eb2f5fd960f4bd9a3708a15baddbdf1d5a55b 127f13925eadd52c341bca0ebaf9ab0dbd78c6468f30a8f262a528bf8de47546'
fm_lint_cache_real_fixture() {
  local sc digest
  if ! sc=$(type -P shellcheck); then
    pass "SKIP (pinned ShellCheck not resolved): $2"
    return 1
  fi
  digest=$(perl -MCwd=realpath -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile(realpath($ARGV[0]))->hexdigest' "$sc")
  case " $FM_LINT_CACHE_RELEASE_BINARIES " in
    *" $digest "*) ;;
    *) pass "SKIP (resolved ShellCheck is not the pinned release build): $2"; return 1 ;;
  esac
  fm_lint_cache_fixture "$1"
  ln -sf "$sc" "$1/fakebin/shellcheck"
}

# fm_lint_cache_expect_real_finding <tmp> <code> <why> <root>...: after a warm
# pass and an edit, the next run must lint again and report <code>.
fm_lint_cache_expect_real_finding() {
  local tmp=$1 code=$2 why=$3
  shift 3
  fm_lint_cache_run "$tmp" "$@"
  [ "$LINT_RC" -ne 0 ] || fail "a recorded pass hid a real finding: $why"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "$code" "real ShellCheck did not report $code ($why)"
}

test_real_shellcheck_finding_two_levels_down_is_not_hidden() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-real)
  fm_lint_cache_real_fixture "$tmp" "${FUNCNAME[0]}" || return 0
  repo="$tmp/repo"
  cat > "$repo/tests/a.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=tests/one.sh
. "$(dirname "${BASH_SOURCE[0]}")/one.sh"
printf '%s\n' "$from_two"
SH
  cat > "$repo/tests/one.sh" <<'SH'
# shellcheck shell=bash
# shellcheck source=tests/two.sh
. "$HERE/two.sh"
SH
  printf '# shellcheck shell=bash\nexport from_two=1\n' > "$repo/tests/two.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -eq 0 ] || fail "the clean fixture did not pass real ShellCheck"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "stored=1" "the clean fixture's pass was not recorded"
  fm_lint_cache_run "$tmp" tests/a.sh
  assert_contains "$LINT_OUT" "lint cache: hits=1 misses=0" "the verified release ShellCheck did not replay its recorded pass"
  printf '# shellcheck shell=bash\n' > "$repo/tests/two.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -ne 0 ] || fail "a recorded pass hid a real finding introduced two source levels down"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "SC2154" "real ShellCheck did not report the unassigned variable"
  pass "real ShellCheck's finding from a file two source levels down is never hidden by a recorded pass"
}

test_real_quoted_source_paths_enter_the_key() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-quoted)
  fm_lint_cache_real_fixture "$tmp" "${FUNCNAME[0]}" || return 0
  repo="$tmp/repo"
  mkdir -p "$repo/lib" "$repo/other lib"
  cat > "$repo/tests/a.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source="lib/two words.sh"
. "lib/two words.sh"
printf '%s\n' "$from_spaced"
SH
  cat > "$repo/tests/b.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source-path="other lib"
. dep.sh
printf '%s\n' "$from_other"
SH
  printf '# shellcheck shell=bash\nexport from_spaced=1\n' > "$repo/lib/two words.sh"
  printf '# shellcheck shell=bash\nexport from_other=1\n' > "$repo/other lib/dep.sh"
  fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh
  [ "$LINT_RC" -eq 0 ] || fail "the clean quoted-path fixture did not pass real ShellCheck"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "stored=2" "the clean quoted-path passes were not recorded"
  printf '# shellcheck shell=bash\n' > "$repo/lib/two words.sh"
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a quoted source path with a space" tests/a.sh
  printf '# shellcheck shell=bash\n' > "$repo/other lib/dep.sh"
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a quoted source-path directory" tests/b.sh
  pass "quoted source filenames and quoted source-path values enter the key"
}

test_real_symlink_swap_between_candidates_misses() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-symlink)
  fm_lint_cache_real_fixture "$tmp" "${FUNCNAME[0]}" || return 0
  repo="$tmp/repo"
  mkdir -p "$repo/lib" "$repo/aux"
  cat > "$repo/tests/a.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck source-path=aux
. dep.sh
printf '%s\n' "$from_dep"
SH
  printf '# shellcheck shell=bash\nexport from_dep=1\n' > "$repo/lib/old.sh"
  printf '# shellcheck shell=bash\n' > "$repo/lib/new.sh"
  ln -s lib/old.sh "$repo/dep.sh"
  ln -s ../lib/new.sh "$repo/aux/dep.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -eq 0 ] || fail "the clean symlink fixture did not pass real ShellCheck"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "stored=1" "the clean symlink pass was not recorded"
  ln -sfn lib/new.sh "$repo/dep.sh"
  ln -sfn ../lib/old.sh "$repo/aux/dep.sh"
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "two source candidates swapped their targets" tests/a.sh
  pass "swapping which file each source candidate resolves to misses"
}

test_real_absolute_source_paths_resolve_from_the_working_directory() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-absolute)
  fm_lint_cache_real_fixture "$tmp" "${FUNCNAME[0]}" || return 0
  repo="$tmp/repo"
  mkdir -p "$repo/lib"
  cat > "$repo/tests/a.sh" <<'SH'
#!/usr/bin/env bash
. /lib/x.sh
printf '%s\n' "$foo"
SH
  cat > "$repo/tests/b.sh" <<'SH'
#!/usr/bin/env bash
f() { printf '%s\n' "$1"; }
# shellcheck source=/lib/x.sh
. "$(f lib/x.sh)"
printf '%s\n' "$foo"
SH
  printf '# shellcheck shell=bash\nexport foo=1\n' > "$repo/lib/x.sh"
  fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh
  [ "$LINT_RC" -eq 0 ] || fail "the clean absolute-path fixture did not pass real ShellCheck"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "stored=2" "the clean absolute-path passes were not recorded"
  printf '# shellcheck shell=bash\n' > "$repo/lib/x.sh"
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "an absolute source command read below the working directory" tests/a.sh
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "an absolute source directive read below the working directory" tests/b.sh
  pass "absolute source commands and directives key the file ShellCheck reads below the working directory"
}

test_real_directive_scope_ends_at_a_top_level_separator() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-directive-scope)
  fm_lint_cache_real_fixture "$tmp" "${FUNCNAME[0]}" || return 0
  repo="$tmp/repo"
  mkdir -p "$repo/lib"
  printf '# shellcheck shell=bash\nexport from_a=1\n' > "$repo/lib/a.sh"
  printf '# shellcheck shell=bash\nexport bar=1\n' > "$repo/lib/c.sh"
  set -- semicolon 'true; . lib/c.sh' background 'true & . lib/c.sh' group '{ true; }; . lib/c.sh'
  while [ "$#" -gt 0 ]; do
    # shellcheck disable=SC2016 # Fixture source text, not an expansion.
    printf '#!/usr/bin/env bash\necho hi\n# shellcheck source=lib/a.sh\n%s\nprintf "%%s\\n" "$bar"\n' "$2" > "$repo/tests/$1.sh"
    shift 2
  done
  cat > "$repo/tests/andor.sh" <<'SH'
#!/usr/bin/env bash
f() { printf '%s\n' "$1"; }
# shellcheck source=lib/c.sh
true && . "$(f lib/c.sh)"
printf '%s\n' "$bar"
SH
  fm_lint_cache_run "$tmp" tests/semicolon.sh tests/background.sh tests/group.sh tests/andor.sh
  [ "$LINT_RC" -eq 0 ] || fail "the clean directive-scope fixture did not pass real ShellCheck"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "stored=4" "a directive-covered source later in its and-or list was not cacheable"
  printf '# shellcheck shell=bash\n' > "$repo/lib/c.sh"
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a source after a top-level ;" tests/semicolon.sh
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a source after a top-level &" tests/background.sh
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a source after a closed group and ;" tests/group.sh
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a directive-covered source later in its and-or list" tests/andor.sh
  pass "a source directive covers only its own and-or list, so a later top-level source enters the key"
}

test_real_unmodelled_constructs_never_hide_a_finding() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo root
  tmp=$(fm_test_tmproot fm-lint-cache-unmodelled)
  fm_lint_cache_real_fixture "$tmp" "${FUNCNAME[0]}" || return 0
  repo="$tmp/repo"
  mkdir -p "$repo/lib"
  printf '# shellcheck shell=bash\nexport from_a=1\n' > "$repo/lib/a.sh"
  printf '# shellcheck shell=bash\nexport bar=1\n' > "$repo/lib/c.sh"
  cat > "$repo/tests/subshell.sh" <<'SH'
#!/usr/bin/env bash
v="$( (true); . lib/c.sh; printf '%s\n' "$bar" )"
printf '%s\n' "$v"
SH
  cat > "$repo/tests/after-subshell.sh" <<'SH'
#!/usr/bin/env bash
echo hi
# shellcheck source=lib/a.sh
y="$( (true) )"; . lib/c.sh
printf '%s\n' "$y" "$bar"
SH
  cat > "$repo/tests/function.sh" <<'SH'
#!/usr/bin/env bash
function f { . lib/c.sh; }
f
printf '%s\n' "$bar"
SH
  cat > "$repo/tests/coproc.sh" <<'SH'
#!/usr/bin/env bash
coproc { . lib/c.sh; printf '%s\n' "$bar"; }
SH
  cat > "$repo/tests/heredoc.sh" <<'SH'
#!/usr/bin/env bash
cat <<EOF
$(. lib/c.sh; echo "$bar")
EOF
SH
  set -- tests/subshell.sh tests/after-subshell.sh tests/function.sh tests/coproc.sh tests/heredoc.sh
  fm_lint_cache_run "$tmp" "$@"
  [ "$LINT_RC" -eq 0 ] || fail "the clean unmodelled-construct fixture did not pass real ShellCheck"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "stored=0 uncacheable=5" "a root with an unmodelled construct was cacheable"
  printf '# shellcheck shell=bash\n' > "$repo/lib/c.sh"
  for root in "$@"; do
    fm_lint_cache_expect_real_finding "$tmp" SC2154 "an unmodelled construct in $root" "$root"
  done
  pass "a subshell inside a substitution, function, coproc, or unquoted heredoc substitution never hides a sourced file's finding"
}

test_unmodelled_constructs_are_uncacheable() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo n=0 form attempt
  local -a unmodelled=() modelled=()
  tmp=$(fm_test_tmproot fm-lint-cache-unmodelled-forms)
  fm_lint_cache_fixture "$tmp"
  repo="$tmp/repo"
  mkdir -p "$repo/lib"
  printf 'dep=1\n' > "$repo/lib/dep.sh"
  # shellcheck disable=SC2016 # Fixture source text, not expansions.
  for form in 'v="$( (true); . lib/dep.sh )"' 'y="$( (true) )"; . lib/dep.sh' 'x=$( $( (true) ) )' \
    'x=`(true)`' 'x=$(a=(1 2); echo "${a[0]}")' 'x=$(cat <(true))' \
    'function f { . lib/dep.sh; }' 'function f ( . lib/dep.sh )' 'coproc { . lib/dep.sh; }' 'coproc true' \
    $'cat <<EOF\n$(. lib/dep.sh)\nEOF' $'cat <<EOF\n`. lib/dep.sh`\nEOF' $'cat <<-EOF\n\t${ . lib/dep.sh; }\n\tEOF' \
    $'echo hi\n# shellcheck source=lib/dep.sh\ntrue; . "$(f)"' $'echo hi\n# shellcheck source=lib/dep.sh\n{ true; } && ( true ) && . "$(f)"'; do
    n=$((n + 1))
    printf '#!/usr/bin/env bash\n%s\n' "$form" > "$repo/tests/u$n.sh"
    unmodelled+=("tests/u$n.sh")
  done
  # shellcheck disable=SC2016 # Fixture source text, not expansions.
  for form in $'cat <<EOF\n\\$(. lib/dep.sh) ${HOME} \\`. lib/dep.sh\\`\nEOF' $'cat <<\'EOF\'\n$(. lib/dep.sh)\nEOF' \
    $'echo hi\n# shellcheck source=lib/dep.sh\ntrue && . "$(f)"'; do
    n=$((n + 1))
    printf '#!/usr/bin/env bash\n%s\n' "$form" > "$repo/tests/m$n.sh"
    modelled+=("tests/m$n.sh")
  done
  for attempt in 1 2; do
    fm_lint_cache_run "$tmp" "${unmodelled[@]}" "${modelled[@]}"
    [ "$LINT_RC" -eq 0 ] || fail "run $attempt failed (exit $LINT_RC)"$'\n'"$LINT_OUT"
  done
  for form in "${unmodelled[@]}"; do
    fm_lint_cache_linted "$tmp" "$form" || fail "$(sed -n '2,$p' "$repo/$form") replayed a recorded pass"
  done
  for form in "${modelled[@]}"; do
    ! fm_lint_cache_linted "$tmp" "$form" || fail "$(sed -n '2,$p' "$repo/$form") was not cacheable"$'\n'"$LINT_OUT"
  done
  assert_contains "$LINT_OUT" "lint cache: hits=${#modelled[@]} misses=${#unmodelled[@]} stored=0 uncacheable=${#unmodelled[@]}" \
    "every unmodelled construct was not counted as uncacheable"
  pass "every construct the lexer does not model makes its root uncacheable, and modelled neighbours stay cacheable"
}

test_real_bash_env_cannot_change_shellcheck_flags() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-bash-env)
  fm_lint_cache_real_fixture "$tmp" "${FUNCNAME[0]}" || return 0
  repo="$tmp/repo"
  # shellcheck disable=SC2016 # Fixture source text, not an expansion.
  printf '#!/usr/bin/env bash\necho $1\n' > "$repo/tests/a.sh"
  printf 'export SHELLCHECK_OPTS=--exclude=SC2086\n' > "$tmp/bash-env"
  BASH_ENV="$tmp/bash-env" fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -ne 0 ] || fail "SHELLCHECK_OPTS from BASH_ENV reached ShellCheck and hid a finding"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "SC2086" "real ShellCheck did not report the unquoted expansion"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -ne 0 ] || fail "a pass recorded under BASH_ENV was replayed"$'\n'"$LINT_OUT"
  pass "BASH_ENV cannot change the flags ShellCheck runs with, so the key matches the invocation"
}

test_unresolvable_source_expression_is_uncacheable() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp attempt
  tmp=$(fm_test_tmproot fm-lint-cache-unresolvable)
  fm_lint_cache_fixture "$tmp"
  # A source argument the lexer cannot delimit, and a dynamic argument with no
  # source= directive, leave the closure unproven; the same dynamic argument
  # under a directive that replaces it is provable.
  # shellcheck disable=SC2016 # Fixture source text, not an expansion.
  printf '#!/usr/bin/env bash\n. "$(printf lib.sh\n' > "$tmp/repo/tests/a.sh"
  # shellcheck disable=SC2016 # Fixture source text, not an expansion.
  printf '#!/usr/bin/env bash\n# shellcheck source=/dev/null\n. "$base/$name.sh"\n' > "$tmp/repo/tests/b.sh"
  # shellcheck disable=SC2016 # Fixture source text, not an expansion.
  printf '#!/usr/bin/env bash\n. "$base/$name.sh"\n' > "$tmp/repo/tests/c.sh"
  for attempt in 1 2; do
    fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh tests/c.sh
    [ "$LINT_RC" -eq 0 ] || fail "run $attempt failed (exit $LINT_RC)"$'\n'"$LINT_OUT"
    fm_lint_cache_linted "$tmp" tests/a.sh tests/c.sh \
      || fail "run $attempt replayed a root whose source argument is not provable"
  done
  ! fm_lint_cache_linted "$tmp" tests/b.sh || fail "a directive-covered source argument was not cacheable"
  assert_contains "$LINT_OUT" "lint cache: hits=1 misses=2 stored=0 uncacheable=2" \
    "the unprovable roots were not counted as uncacheable misses"
  pass "a source argument the key cannot prove makes its root uncacheable unless a directive names the file"
}

test_script_wrapper_shellcheck_disables_the_cache() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp attempt
  tmp=$(fm_test_tmproot fm-lint-cache-wrapper)
  fm_lint_cache_fixture "$tmp"
  cp "$tmp/stub.sh" "$tmp/fakebin/shellcheck"
  chmod +x "$tmp/fakebin/shellcheck"
  printf '#!/usr/bin/env bash\necho ok\n' > "$tmp/repo/tests/a.sh"
  for attempt in 1 2; do
    fm_lint_cache_run "$tmp" tests/a.sh
    [ "$LINT_RC" -eq 0 ] || fail "run $attempt failed (exit $LINT_RC)"$'\n'"$LINT_OUT"
    fm_lint_cache_linted "$tmp" tests/a.sh || fail "run $attempt replayed a pass recorded through a wrapper script"
  done
  assert_contains "$LINT_OUT" "lint cache: hits=0 misses=1 stored=0 uncacheable=0 scope=local state=disabled" \
    "a wrapper-script ShellCheck did not disable the cache with a summary"
  [ -z "$(find "$tmp/cache" -type f 2>/dev/null)" ] || fail "a wrapper-script ShellCheck recorded a cache entry"
  pass "a ShellCheck that is a script wrapper is never trusted for caching"
}

test_fifo_entry_lints_every_root() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp entry
  tmp=$(fm_test_tmproot fm-lint-cache-fifo)
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\necho one\n' > "$tmp/repo/tests/a.sh"
  printf '#!/usr/bin/env bash\necho two\n' > "$tmp/repo/tests/b.sh"
  fm_lint_cache_warm "$tmp" tests/a.sh tests/b.sh
  entry=$(find "$tmp/cache" -type f | LC_ALL=C sort | head -n1)
  rm -f "$entry"
  mkfifo "$entry"
  FM_TEST_TIMEOUT=60 fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh
  [ "$LINT_RC" -ne 124 ] || fail "a FIFO cache entry hung the run"
  [ "$LINT_RC" -eq 0 ] || fail "a FIFO cache entry failed the run (exit $LINT_RC)"$'\n'"$LINT_OUT"
  fm_lint_cache_linted "$tmp" tests/a.sh tests/b.sh \
    || fail "a FIFO cache entry did not make the run lint every root"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "not a regular file" "the FIFO entry was not reported as corrupt"
  pass "a FIFO or other special node at an entry name discards every hit without blocking"
}

test_summary_counts_every_root_in_every_state() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-summary)
  fm_lint_cache_fixture "$tmp"
  repo="$tmp/repo"
  printf '#!/usr/bin/env bash\necho ok\n' > "$repo/tests/a.sh"
  mkdir -p "$tmp/cache"
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$tmp/cache"
    fm_lint_cache_run "$tmp" tests/a.sh
    chmod 755 "$tmp/cache"
    assert_contains "$LINT_OUT" "lint cache: hits=0 misses=1 stored=0 uncacheable=0 scope=local state=disabled" \
      "a disabled cache printed no numeric summary"
  fi
  fm_lint_cache_run "$tmp" --audit-cache "$tmp/cache" tests/a.sh
  assert_contains "$LINT_OUT" "lint cache: hits=0 misses=1 stored=0 uncacheable=0 scope=local state=bypassed" \
    "the uncached audit printed no numeric summary"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-lint-workflows.sh"
  chmod +x "$repo/bin/fm-lint-workflows.sh"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m base
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  fm_lint_cache_run "$tmp"
  [ "$LINT_RC" -eq 0 ] || fail "the zero-target run failed (exit $LINT_RC)"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "lint cache: hits=0 misses=0 stored=0 uncacheable=0 scope=local state=on" \
    "a zero-target run printed no numeric summary"
  pass "every run prints its cache state with hits and misses that cover every selected root"
}

test_audit_without_attribution_reports_incomplete() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo head
  tmp=$(fm_test_tmproot fm-lint-cache-incomplete)
  fm_lint_cache_fixture "$tmp"
  repo="$tmp/repo"
  printf '#!/usr/bin/env bash\n# LINT-BAD\necho bad\n' > "$repo/tests/a.sh"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m base
  head=$(git -C "$repo" rev-parse HEAD)
  fm_lint_cache_run "$tmp" --audit-cache "$tmp/missing-cache" tests/a.sh
  [ "$LINT_RC" -ne 0 ] || fail "the audit passed a root with findings"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "AUDIT INCOMPLETE: tests/a.sh has findings at commit $head (partition all)" \
    "an unattributed finding did not report an incomplete audit naming the commit, partition and root"
  assert_contains "$LINT_OUT" "is unproven" "the incomplete audit claimed its candidate key was replayed"
  printf '%s\n' "$LINT_OUT" | grep -Eq 'candidate key [0-9a-f]{64}' \
    || fail "the incomplete audit did not name the recomputed candidate key"$'\n'"$LINT_OUT"
  fm_lint_cache_run "$tmp" --telemetry "$tmp/cached.tsv" tests/a.sh
  [ -s "$tmp/cached.cache.tsv" ] || fail "the cached run wrote no sidecar"
  fm_lint_cache_run "$tmp" --audit-cache "$tmp/missing-cache" --audit-record "$tmp/cached.cache.tsv" tests/a.sh
  [ "$LINT_RC" -eq 1 ] || fail "an attributed finding did not report the plain findings status (exit $LINT_RC)"$'\n'"$LINT_OUT"
  assert_not_contains "$LINT_OUT" "AUDIT INCOMPLETE" "a sidecar proving the root was linted still reported an incomplete audit"
  pass "a finding no record attributes reports an incomplete audit, and a covering sidecar proves it"
}

test_source_in_every_command_position_is_detected() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo n=0 form root
  local -a sourcing=() quiet=()
  tmp=$(fm_test_tmproot fm-lint-cache-position)
  fm_lint_cache_fixture "$tmp"
  repo="$tmp/repo"
  mkdir -p "$repo/lib"
  printf 'dep=1\n' > "$repo/lib/dep.sh"
  # shellcheck disable=SC2016 # Fixture source text, not expansions.
  for form in '. lib/dep.sh' 'true; . lib/dep.sh' 'true & . lib/dep.sh' 'true && . lib/dep.sh' \
    'false || . lib/dep.sh' 'true | . lib/dep.sh' 'true |& . lib/dep.sh' '( . lib/dep.sh )' \
    '{ . lib/dep.sh; }' 'x=$(. lib/dep.sh)' 'x=`. lib/dep.sh`' 'if true; then . lib/dep.sh; fi' \
    'for i in 1; do . lib/dep.sh; done' 'if false; then :; else . lib/dep.sh; fi' \
    'if false; then :; elif . lib/dep.sh; then :; fi' 'if . lib/dep.sh; then :; fi' \
    'while . lib/dep.sh; do break; done' 'until . lib/dep.sh; do :; done' '! . lib/dep.sh' \
    'time . lib/dep.sh' 'x=1 source lib/dep.sh' 'source </dev/null lib/dep.sh'; do
    n=$((n + 1))
    printf '#!/usr/bin/env bash\n%s\n' "$form" > "$repo/tests/s$n.sh"
    sourcing+=("tests/s$n.sh")
  done
  # shellcheck disable=SC2016 # Fixture source text, not expansions.
  for form in "bash -c '. \"\$1\"' _ lib/dep.sh" "jq 'if . == 1 then . else . end' lib/dep.sh" \
    $'cat <<\'EOF\'\n. lib/dep.sh\nEOF' '# . lib/dep.sh' 'printf "%s\n" . lib/dep.sh'; do
    n=$((n + 1))
    printf '#!/usr/bin/env bash\n%s\n' "$form" > "$repo/tests/q$n.sh"
    quiet+=("tests/q$n.sh")
  done
  fm_lint_cache_run "$tmp" "${sourcing[@]}" "${quiet[@]}"
  fm_lint_cache_run "$tmp" "${sourcing[@]}" "${quiet[@]}"
  printf 'dep=2\n' > "$repo/lib/dep.sh"
  fm_lint_cache_run "$tmp" "${sourcing[@]}" "${quiet[@]}"
  for root in "${sourcing[@]}"; do
    fm_lint_cache_linted "$tmp" "$root" \
      || fail "a source command in $(sed -n 2p "$repo/$root") replayed a pass after its dependency changed"
  done
  for root in "${quiet[@]}"; do
    ! fm_lint_cache_linted "$tmp" "$root" \
      || fail "text that is not a source command made $(sed -n 2,4p "$repo/$root") depend on the sourced file"$'\n'"$LINT_OUT"
  done
  pass "a source command after every command boundary is a dependency, and quoted, heredoc, comment, and argument text is not"
}

test_real_scriptdir_expands_only_as_a_leading_component() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-scriptdir)
  fm_lint_cache_real_fixture "$tmp" "${FUNCNAME[0]}" || return 0
  repo="$tmp/repo"
  mkdir -p "$repo/lib" "$repo/otherSCRIPTDIR"
  # shellcheck disable=SC2016 # Fixture source text, not an expansion.
  printf '#!/usr/bin/env bash\n. lib/SCRIPTDIR-data.sh\nprintf "%%s\\n" "$from_a"\n' > "$repo/tests/a.sh"
  # shellcheck disable=SC2016 # Fixture source text, not an expansion.
  printf '#!/usr/bin/env bash\n# shellcheck source-path=otherSCRIPTDIR\n. dep.sh\nprintf "%%s\\n" "$from_b"\n' > "$repo/tests/b.sh"
  # shellcheck disable=SC2016 # Fixture source text, not an expansion.
  printf '#!/usr/bin/env bash\n# shellcheck source-path=SCRIPTDIR\n. sibling.sh\nprintf "%%s\\n" "$from_c"\n' > "$repo/tests/c.sh"
  printf '# shellcheck shell=bash\nexport from_a=1\n' > "$repo/lib/SCRIPTDIR-data.sh"
  printf '# shellcheck shell=bash\nexport from_b=1\n' > "$repo/otherSCRIPTDIR/dep.sh"
  printf '# shellcheck shell=bash\nexport from_c=1\n' > "$repo/tests/sibling.sh"
  fm_lint_cache_run "$tmp" tests/a.sh tests/b.sh tests/c.sh
  [ "$LINT_RC" -eq 0 ] || fail "the clean SCRIPTDIR fixture did not pass real ShellCheck"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "stored=3" "the clean SCRIPTDIR passes were not recorded"
  printf '# shellcheck shell=bash\n' > "$repo/lib/SCRIPTDIR-data.sh"
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a literal path containing SCRIPTDIR" tests/a.sh
  printf '# shellcheck shell=bash\n' > "$repo/otherSCRIPTDIR/dep.sh"
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a source-path containing SCRIPTDIR" tests/b.sh
  printf '# shellcheck shell=bash\n' > "$repo/tests/sibling.sh"
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a source-path=SCRIPTDIR lookup" tests/c.sh
  pass "SCRIPTDIR expands only as a leading path component and literal paths containing it stay in the key"
}

test_real_redirected_source_is_uncacheable() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp repo
  tmp=$(fm_test_tmproot fm-lint-cache-redirect)
  fm_lint_cache_real_fixture "$tmp" "${FUNCNAME[0]}" || return 0
  repo="$tmp/repo"
  mkdir -p "$repo/lib"
  # shellcheck disable=SC2016 # Fixture source text, not an expansion.
  printf '#!/usr/bin/env bash\nsource </dev/null lib/dep.sh\nprintf "%%s\\n" "$from_dep"\n' > "$repo/tests/a.sh"
  printf '# shellcheck shell=bash\nexport from_dep=1\n' > "$repo/lib/dep.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -eq 0 ] || fail "the clean redirected-source fixture did not pass real ShellCheck"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "uncacheable=1" "a source command with a redirection was cacheable"
  printf '# shellcheck shell=bash\n' > "$repo/lib/dep.sh"
  fm_lint_cache_expect_real_finding "$tmp" SC2154 "a source command with an intervening redirection" tests/a.sh
  pass "a source command with a redirection is uncacheable and its dependency edit is never hidden"
}

test_unverified_shellcheck_launcher_disables_the_cache() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp attempt
  tmp=$(fm_test_tmproot fm-lint-cache-untrusted)
  fm_lint_cache_fixture "$tmp"
  cp "$(fm_lint_cache_launcher untrusted)" "$tmp/fakebin/shellcheck"
  printf '#!/usr/bin/env bash\necho ok\n' > "$tmp/repo/tests/a.sh"
  for attempt in 1 2; do
    fm_lint_cache_run "$tmp" tests/a.sh
    [ "$LINT_RC" -eq 0 ] || fail "run $attempt failed (exit $LINT_RC)"$'\n'"$LINT_OUT"
    fm_lint_cache_linted "$tmp" tests/a.sh || fail "run $attempt replayed a pass recorded through an unverified launcher"
  done
  assert_contains "$LINT_OUT" "is not a verified pinned release build" "the unverified launcher was not named"
  assert_contains "$LINT_OUT" "state=disabled" "the unverified launcher did not disable the cache"
  [ -z "$(find "$tmp/cache" -type f 2>/dev/null)" ] || fail "an unverified launcher recorded a cache entry"
  pass "a compiled launcher that is not a verified pinned release build lints but never reads or writes entries"
}

test_unreadable_entries_directory_discards_every_hit() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp
  tmp=$(fm_test_tmproot fm-lint-cache-entries-dir)
  if [ "$(id -u)" -eq 0 ]; then
    pass "SKIP (root ignores directory permissions): ${FUNCNAME[0]}"
    return
  fi
  fm_lint_cache_fixture "$tmp"
  printf '#!/usr/bin/env bash\necho one\n' > "$tmp/repo/tests/a.sh"
  fm_lint_cache_warm "$tmp" tests/a.sh
  chmod 0100 "$tmp/cache/fm-lint-cache-v1"
  fm_lint_cache_run "$tmp" tests/a.sh
  chmod 0755 "$tmp/cache/fm-lint-cache-v1"
  fm_lint_cache_linted "$tmp" tests/a.sh \
    || fail "an execute-only entries directory still yielded a hit"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "not a readable, searchable directory" "the unreadable entries directory was not reported"
  pass "an entries directory that is not readable and searchable discards every hit"
}

test_missing_library_prints_the_summary() {
  fm_lint_cache_skip_unbounded "${FUNCNAME[0]}" && return
  local tmp
  tmp=$(fm_test_tmproot fm-lint-cache-no-lib)
  fm_lint_cache_fixture "$tmp"
  rm -f "$tmp/repo/bin/fm-lint-cache-lib.sh"
  printf '#!/usr/bin/env bash\n# LINT-BAD\necho bad\n' > "$tmp/repo/tests/a.sh"
  fm_lint_cache_run "$tmp" tests/a.sh
  [ "$LINT_RC" -eq 1 ] || fail "a missing cache library changed the lint result (exit $LINT_RC)"$'\n'"$LINT_OUT"
  assert_contains "$LINT_OUT" "lint cache: hits=0 misses=1 stored=0 uncacheable=0 scope=local state=disabled" \
    "a requested cache without its library printed no disabled summary"
  FM_TEST_CACHE_DIR='' fm_lint_cache_run "$tmp" tests/a.sh
  assert_contains "$LINT_OUT" "lint cache: hits=0 misses=1 stored=0 uncacheable=0 scope=local state=off" \
    "an unrequested cache without its library printed no off summary"
  pass "a missing cache library still prints the numeric summary with its state"
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
  test_real_shellcheck_finding_two_levels_down_is_not_hidden \
  test_real_quoted_source_paths_enter_the_key \
  test_real_symlink_swap_between_candidates_misses \
  test_real_absolute_source_paths_resolve_from_the_working_directory \
  test_real_directive_scope_ends_at_a_top_level_separator \
  test_real_unmodelled_constructs_never_hide_a_finding \
  test_unmodelled_constructs_are_uncacheable \
  test_real_bash_env_cannot_change_shellcheck_flags \
  test_unresolvable_source_expression_is_uncacheable \
  test_script_wrapper_shellcheck_disables_the_cache \
  test_fifo_entry_lints_every_root \
  test_summary_counts_every_root_in_every_state \
  test_audit_without_attribution_reports_incomplete \
  test_source_in_every_command_position_is_detected \
  test_real_scriptdir_expands_only_as_a_leading_component \
  test_real_redirected_source_is_uncacheable \
  test_unverified_shellcheck_launcher_disables_the_cache \
  test_unreadable_entries_directory_discards_every_hit \
  test_missing_library_prints_the_summary
