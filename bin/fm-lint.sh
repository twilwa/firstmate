#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI selects
# canonical partitions; no-mistakes invokes the context-selected default, so
# both use this owner without duplicating lint configuration.
# The explicit --fast mode is local-only and disables ShellCheck's extended
# dataflow analysis while preserving ordinary shell lint checks and source
# following. Hosted CI's full canonical set (main pushes and upgraded
# pull-request runs) and every --partition attempt --norc --external-sources
# with full dataflow for each canonical root except the known-heavy roots
# (see the memory fallback below), which run once with the retry's flags.
# A local run's default
# changed-file mode (including the no-mistakes lint step) drops --external-sources, keeps
# dataflow, and excludes SC1091, SC2034, SC2153, and SC2329, the codes that
# need library context. CI checks those codes
# on source-following attempts (see the memory fallback below). Explicit
# paths attempt --external-sources with the selected dataflow mode.
# Tests stop source analysis at imported production modules because CI analyzes
# every production shell separately as a canonical, source-aware root.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed GitHub workflow, including a self-broken ci.yml, fails locally
# before merge instead of only failing to run as CI.
#
# With no explicit paths, the file set and source-following posture depend
# on context:
#   - A run is hosted only under the hosted workflow contract: GITHUB_ACTIONS=true
#     together with FM_LINT_REQUIRE_BOUNDS=1, as .github/workflows/ci.yml sets
#     them. A bare CI=true, or GITHUB_ACTIONS without required bounds, is a
#     local run.
#   - Hosted CI without --changed (main pushes) lints the full canonical set:
#     bin/*.sh bin/backends/*.sh tests/*.sh, with --external-sources and full
#     dataflow first; memory failures may take the narrower retry below,
#     where known-heavy roots start.
#   - --changed (CI pull requests) lints only the canonical-set files changed
#     since the merge-base, still with --external-sources and full dataflow
#     (known-heavy roots aside), so the PR gate stays source-aware on the
#     files it checks. Outside hosted
#     CI, --changed keeps that source-aware changed set but never upgrades.
#   - Otherwise a local run, on any branch including main, lints only the
#     canonical-set files changed since the merge-base against origin/main
#     (or local main), including uncommitted local edits, via plain local
#     `git diff` (no network, no `gh`). That local pass drops
#     --external-sources and excludes SC1091, SC2034, SC2153, and SC2329. A
#     branch with zero matching changed files skips ShellCheck and prints a
#     "no changed lint targets" note, then still runs the backend-purity
#     check and validates workflows. When no changed set can be computed
#     (outside a Git work tree, or no merge-base) a local run refuses with
#     exit 2 instead of falling back to the full canonical set; lint the full
#     set in a capped sandbox (for example a Boat sandbox started with
#     --no-env, one --partition at a time) or in CI.
#   - Only hosted CI's --changed run upgrades to the full canonical,
#     source-aware set above when a lint-definition file changed (including a
#     delete or rename of fm-lint.sh, fm-lint-cache-lib.sh,
#     fm-lint-workflows.sh, a pinned installer, or fm-timeout-lib.sh), or
#     when a changed, deleted, or renamed file is sourced by another canonical script (via `# shellcheck source=`
#     on the merge-base tree). Local runs, including the no-mistakes lint step
#     and a worker's own lint, never take that upgrade: the source-following
#     full set needs many GiB per root and exhausts a shared dev host.
#   - In either changed-file mode, a failed `git diff` against the merge-base,
#     or a failed sort of its paths, refuses with exit 2 rather than reading as
#     an empty changed set.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config, without the workflow YAML check.
# Explicit core bin/ and bin/backends/ scripts still receive the
# backend-purity check. The backend-purity check rejects direct Beads CLI
# invocations in the core bin/ and bin/backends/ scripts so every configured
# backlog backend follows the same tasks-axi lifecycle path.
#
# Lint defaults to two concurrency-limited workers over two stable logical
# shards, and each worker runs ONE canonical root per ShellCheck process, so a
# run holds at most JOBS concurrent ShellCheck processes. CI partitions default
# to one worker so large source-aware ShellCheck processes cannot overlap on a
# memory-limited runner. A local run (outside hosted CI) also holds workers x
# FM_LINT_ROOT_MEMORY_KIB within FM_LINT_LOCAL_MEMORY_BUDGET_GIB (default 16):
# the default drops to one worker under the 12 GiB cap, and an explicit worker
# count or per-root cap above the budget refuses. Diagnostics replay in stable
# shard/root order.
# FM_LINT_JOBS/--jobs change concurrency, not diagnostics or exit selection.
# --partition <k>of<N> splits the selected inventory across N CI runners,
# where N is the owned partition count below. Partitions of the full
# canonical set are complete, disjoint, and packed by measured per-root
# duration hints (byte weight stays only the two local workers' proxy; an
# unhinted root packs on FM_LINT_DEFAULT_ROOT_WEIGHT_MS); --list-files
# exposes their actual roots. --changed --partition splits only the changed
# roots the same way, and an empty partition is a successful no-op for
# ShellCheck while still running workflow lint and backend-purity checks.
# Partition mode does not accept --fast or explicit paths. Each partition also
# runs workflow lint and backend-purity checks, keeping either invocation
# independently useful.
#
# With FM_LINT_REQUIRE_BOUNDS=1, which CI sets, every per-root ShellCheck
# process runs under an enforced envelope: a wall deadline
# (FM_LINT_ROOT_SECONDS, default 1200), a terminate-then-kill cleanup grace
# (FM_LINT_ROOT_GRACE, default 5), and a per-process address-space limit
# (FM_LINT_ROOT_MEMORY_KIB, default 12582912 = 12 GiB of virtual address
# space per analysis process). The sizing rationale and RSS reduction threshold
# live beside ROOT_MEMORY_KIB below. This is not a resident-memory ceiling;
# check aggregate runner RSS in CI. The watchdog uses the shared
# bin/fm-timeout-lib.sh group-kill pattern, so a deadline or an interrupt
# removes the owned process group. Bounds mode proves the watchdog can
# actually bound a probe command and that the host accepts the memory limit
# BEFORE any root starts; when either check fails the run refuses with a
# named error, so a required-bounds run never lints uncapped. A local run
# (outside hosted CI) without FM_LINT_REQUIRE_BOUNDS applies the same
# envelope whenever the host accepts ulimit -v and the watchdog runs. On a
# host that cannot (macOS rejects the address-space limit) a local full
# canonical selection (a --partition) refuses and points to a capped sandbox
# or CI, and a smaller local selection refuses the same way before ShellCheck
# unless FM_LINT_ALLOW_UNBOUNDED_LOCAL=1 is set, in which case it prints a
# warning and lints each root unbounded in its own ShellCheck process; the
# local memory budget is enforceable only where that per-root limit is
# active. Local lint workers run under nice -n 10 when an external nice is on
# PATH, and at normal priority otherwise.
#
# If a source-following root exits with a memory failure, it is retried once
# without --external-sources under the same memory limit and only the time
# left in that root's original deadline; with under a second left, the
# memory failure stands without a retry. A clean retry passes
# with an explicit memory-fallback reason and warning; only the same
# cross-file-dependent codes omitted in local no-source lint are excluded.
# Other findings and failed retries still fail lint. The retry's diagnostics
# replace the failed attempt's output; peak RSS is the maximum of both attempts.
# A root on the known-heavy list (fm_lint_known_heavy_root) skips the
# source-following attempt it always loses and runs once with the retry's
# exact flags and its full deadline, whenever bounds are enforced at or under
# the default cap and the run is not --fast; a clean pass records reason
# known-heavy with the same disclosure, and anything else fails as above.
#
# Per-root evidence is incremental: workers append begin/end records (root,
# mode, shard, start, end, duration, final exit status, reason, peak RSS when
# measured, and whether the final attempt followed sources) to a roots log
# as each root completes, so a mid-run kill still leaves the completed record
# and names the root in flight as begun-but-unfinished. With --telemetry the
# log is retained at
# <telemetry-without-.tsv>.roots.tsv (or <telemetry>.roots.tsv if there is no
# .tsv suffix); otherwise it lives only in the
# run's scratch dir. Reason values are ok, findings, memory-fallback,
# known-heavy, timeout, memory, signal:<sig>, limit-unavailable, or error:<rc>.
# Memory requires process-level evidence (a GHC exhaustion status or runtime
# error on stderr), not an echoed source excerpt or an OOM phrase in a
# filename. In partition mode begin/end
# lines also stream to stderr, and an abnormal root end is always reported
# there.
#
# Per-root pass cache: with FM_LINT_CACHE_DIR set to an absolute directory,
# every mode (changed-file, partitions, explicit paths, --fast) looks up each
# selected root's key in bin/fm-lint-cache-lib.sh, which owns the key, the
# entry format, and the audit, and lints only the roots without a recorded
# pass for that exact key. Every run prints the library's "lint cache:"
# summary line with its state, and with --telemetry writes the per-root
# sidecar <telemetry-without-.tsv>.cache.tsv. A corrupt entry or an unreadable
# cache lints every root; a missing library lints every root with a warning.
# --audit-cache <dir> and --audit-record <sidecar> (repeatable) lint every
# root without reading or writing the cache and, after linting, report each
# root with findings whose key <dir> records as a pass, or that a same-commit
# cached run's sidecar recorded as a hit or stored pass, as "STALE LINT CACHE
# KEY <key>", exiting 3; a finding neither attributes is reported as "AUDIT
# INCOMPLETE".
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
# source_followed_directives counts directives only for roots whose final
# attempt followed sources, not roots that passed or failed a no-source retry.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override concurrent worker count
#   fm-lint.sh --partition <k>of<N>      lint one canonical CI partition (see fallback above)
#   fm-lint.sh --changed ...            lint changed canonical roots (CI pull requests keep source-aware analysis; in hosted CI only, sourced helpers and lint-definition files upgrade to the full set)
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --audit-cache <dir> [--audit-record <sidecar>]... ...
#                                      uncached run that names stale cache keys
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u
# Internal Bash processes (workers, the per-root payload, the watchdog) must
# not run a startup file that could re-export SHELLCHECK_OPTS or change the
# environment ShellCheck sees, so the invocation always matches the cache key.
unset BASH_ENV ENV

REQUIRED_SHELLCHECK=0.11.0

# How many CI runners the canonical inventory splits across, packed by the
# measured per-root durations in fm_lint_root_duration_hints. One owner: a
# --partition argument whose of<N> disagrees is refused, the same contract
# bin/fm-test-run.sh applies to its serial shard count.
FM_LINT_CI_PARTITIONS=4

# Balance hint for a canonical root with no measured duration, in
# milliseconds. Rounded above three times the current CI mean root cost so a
# new file lands with headroom rather than being packed as free; keep it
# conservative like the runner's unmeasured-script default.
FM_LINT_DEFAULT_ROOT_WEIGHT_MS=15000
# Cross-file codes that need --external-sources. No-source checks (local
# changed-file mode and memory fallback) cannot judge them.
LOCAL_NOX_EXCLUDE=SC1091,SC2034,SC2153,SC2329
# Default per-root address-space cap in KiB (12 GiB); the sizing rationale
# lives beside ROOT_MEMORY_KIB below.
FM_LINT_DEFAULT_ROOT_MEMORY_KIB=12582912
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

# The sibling timeout library supplies the shared group-kill watchdog that
# bounds each root when FM_LINT_REQUIRE_BOUNDS=1 requires it and, where the
# host allows, in local runs; without the library a required-bounds run or a
# local full canonical lint refuses rather than lint uncapped, and any other
# local lint refuses too unless FM_LINT_ALLOW_UNBOUNDED_LOCAL=1.
if [ -r "$SELF_DIR/fm-timeout-lib.sh" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SELF_DIR/fm-timeout-lib.sh"
fi

# The sibling cache library owns the per-root pass cache's key, entry format,
# and stale-key audit; without it a requested cache is reported unavailable and
# every root is linted.
if [ -r "$SELF_DIR/fm-lint-cache-lib.sh" ]; then
  # shellcheck source=bin/fm-lint-cache-lib.sh
  . "$SELF_DIR/fm-lint-cache-lib.sh"
fi

FM_LINT_WORKER_RUN_PID=
FM_LINT_WORKER_ARGS=()
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_RUN_PID" ] || return 0
  kill "$FM_LINT_WORKER_RUN_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_RUN_PID" 2>/dev/null || true
  FM_LINT_WORKER_RUN_PID=
}

fm_lint_now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local seconds=${EPOCHREALTIME%.*} micros=${EPOCHREALTIME#*.}
    printf '%s\n' "$((seconds * 1000 + 10#${micros:0:3}))"
  else
    printf '%s\n' "$(($(date +%s) * 1000))"
  fi
}

# Names are listed only for signal numbers that agree on Linux and macOS; any
# other number reports itself.
fm_lint_signal_name() {  # <signal-number>
  case "$1" in
    1) printf 'HUP\n' ;; 2) printf 'INT\n' ;; 3) printf 'QUIT\n' ;;
    6) printf 'ABRT\n' ;; 8) printf 'FPE\n' ;; 9) printf 'KILL\n' ;;
    11) printf 'SEGV\n' ;; 13) printf 'PIPE\n' ;; 14) printf 'ALRM\n' ;;
    15) printf 'TERM\n' ;; 24) printf 'XCPU\n' ;; 25) printf 'XFSZ\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Peak RSS of a finished root process: GNU time writes max_rss_kib=<KiB> while
# BSD time -l writes "maximum resident set size" in bytes.
fm_lint_root_rss() {  # <rss-file>
  local file=$1 kib
  kib=$(awk '
    /^max_rss_kib=/ { value = substr($0, 13) + 0; found = 1 }
    /maximum resident set size/ { value = int($1 / 1024); found = 1 }
    END { if (found) print value }
  ' "$file" 2>/dev/null)
  printf '%s\n' "${kib:-unavailable}"
}

fm_lint_max_root_rss() {  # <rss-kib> <rss-kib>
  local first=$1 second=$2
  case "$first" in ''|unavailable|*[!0-9]*) printf '%s\n' "$second"; return ;; esac
  case "$second" in ''|unavailable|*[!0-9]*) printf '%s\n' "$first"; return ;; esac
  if [ "$first" -gt "$second" ]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' "$second"
  fi
}

# Map a root's exit status onto the reported reason vocabulary without
# pretending every signal or nonzero exit is a memory kill: only process-level
# memory-failure evidence earns the memory reason - GHC's heap-exhaustion
# status 251, or a complete runtime memory-error line on the root's stderr -
# and that evidence is checked before a generic findings or signal reason.
# Diagnostics and their echoed source excerpts are on stdout and never count,
# and each stderr form is matched whole to its line end, so a root path that
# merely contains OOM words inside a file error never counts either.
fm_lint_classify_root() {  # <rc> <root-stderr-file>
  local rc=$1 err=$2
  case "$rc" in
    0) printf 'ok\n'; return 0 ;;
    97) printf 'limit-unavailable\n'; return 0 ;;
    251) printf 'memory\n'; return 0 ;;
  esac
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] && [ "$rc" = 124 ]; then
    printf 'timeout\n'; return 0
  fi
  if grep -qE '^[^[:space:]:]+: (out of memory \(requested [0-9]+ bytes\)|Heap exhausted;)$|: resource exhausted \((Cannot allocate memory|out of memory)\)$' "$err" 2>/dev/null; then
    printf 'memory\n'; return 0
  fi
  if [ "$rc" = 1 ]; then
    printf 'findings\n'; return 0
  fi
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ]; then
    case "$rc" in
      137)
        # The perl watchdog exits 124 on its own bound, so a bare 137 is a real
        # SIGKILL of the child; GNU/BSD timeout instead report 137 when their
        # configured kill had to fire at the bound.
        if [ "${FM_LINT_INTERNAL_BOUNDED:-}" = perl ]; then
          printf 'signal:KILL\n'; return 0
        fi
        printf 'timeout\n'; return 0
        ;;
    esac
  fi
  case "$rc" in
    ''|*[!0-9]*) printf 'error\n' ;;
    *)
      if [ "$rc" -gt 128 ]; then
        printf 'signal:%s\n' "$(fm_lint_signal_name "$((rc - 128))")"
      else
        printf 'error:%s\n' "$rc"
      fi
      ;;
  esac
}

# Run one ShellCheck invocation under the given deadline and the per-root
# address-space limit, returning its exit status in FM_LINT_LAST_RC.
fm_lint_exec_root() {  # <path> <stdout-file> <stderr-file> <rss-file> <seconds> <args...>
  local path=$1 root_out=$2 root_err=$3 rss_file=$4 seconds=$5 invocation_rc=0
  shift 5
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ]; then
    # The watchdog runs in a process group of its own (the same setpgrp hop the
    # workers use), so the owner's TERM-then-KILL group sweep cannot kill it
    # before it has forwarded the signal to the root's own group. If the worker
    # dies before its trap can signal the watchdog, the watchdog's parent-death
    # check still starts the same terminate-then-kill escalation; the worker
    # names itself as that owner before the launch, so a worker that dies while
    # the watchdog is still starting is detected too.
    ( FM_EXEC_TIMED_OWNER_PID=$$ exec "${FM_LINT_PERL_BIN:-perl}" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        "${BASH:-bash}" "$SELF" --internal-timed \
        "$seconds" "$FM_LINT_INTERNAL_GRACE" \
        "${BASH:-bash}" "$SELF" --internal-root "$rss_file" "$FM_LINT_INTERNAL_MEMORY_KIB" \
        "$FM_LINT_SHELLCHECK" "$@" -- "$path" ) > "$root_out" 2> "$root_err" &
    FM_LINT_WORKER_RUN_PID=$!
    wait "$FM_LINT_WORKER_RUN_PID" || invocation_rc=$?
    FM_LINT_WORKER_RUN_PID=
  else
    env -u SHELLCHECK_OPTS "$FM_LINT_SHELLCHECK" "$@" -- "$path" > "$root_out" 2> "$root_err" &
    FM_LINT_WORKER_RUN_PID=$!
    wait "$FM_LINT_WORKER_RUN_PID" || invocation_rc=$?
    FM_LINT_WORKER_RUN_PID=
  fi
  FM_LINT_LAST_RC=$invocation_rc
}

# Known-heavy roots: canonical roots whose source-following attempt exceeded
# the default per-root cap on every hosted full-set run measured (40 of 40
# across five 2026-11 runs) and then passed the memory retry. A bounded,
# source-following, non-fast run at or under that cap lints them directly with
# the retry's exact flags instead of spending a doomed first attempt; any
# other root that grows past the cap still takes the retry. Remove an entry
# once its source-following attempt fits under the cap.
fm_lint_known_heavy_root() {  # <path>
  [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ] \
    && [ "${FM_LINT_INTERNAL_FAST:-0}" -ne 1 ] \
    && [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] \
    && [ "${FM_LINT_INTERNAL_MEMORY_KIB:-0}" -le "$FM_LINT_DEFAULT_ROOT_MEMORY_KIB" ] \
    || return 1
  case "${1#"$ROOT"/}" in
    # Follows bin/fm-pending-reply-lib.sh and bin/fm-marker-lib.sh; ~8 GiB peak.
    tests/fm-pending-reply.test.sh) return 0 ;;
    # Follows bin/fm-supervise-daemon.sh and tests/wake-helpers.sh; ~8 GiB peak.
    tests/fm-daemon.test.sh) return 0 ;;
    # Follows bin/fm-watch.sh's closure; ~8 GiB peak.
    tests/fm-launch-prompt-signals-live-e2e.test.sh) return 0 ;;
    # Largest source closure in the set (42 files); ~8 GiB peak.
    bin/fm-spawn.sh) return 0 ;;
    # Source closure of 34 files; ~8 GiB peak.
    bin/fm-teardown.sh) return 0 ;;
    # Source closure of 29 files; ~8 GiB peak.
    bin/fm-watch.sh) return 0 ;;
    # Follows bin/fm-watch.sh's closure; ~8 GiB peak.
    tests/fm-watch-open-decisions.test.sh) return 0 ;;
    # Follows tests/lib.sh's closure; ~8 GiB peak.
    tests/fm-stat-shadowing.test.sh) return 0 ;;
  esac
  return 1
}

# The worker's flags for a root's first attempt, from the selected analysis mode.
fm_lint_build_worker_args() {
  FM_LINT_WORKER_ARGS=(--norc)
  if [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
    FM_LINT_WORKER_ARGS+=(--external-sources)
  fi
  if [ -n "${FM_LINT_INTERNAL_EXCLUDE:-}" ]; then
    FM_LINT_WORKER_ARGS+=(--exclude="$FM_LINT_INTERNAL_EXCLUDE")
  fi
  if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
    FM_LINT_WORKER_ARGS+=(--extended-analysis=false)
  fi
}

# The flags of a root's one final attempt absent a memory retry: the
# known-heavy no-source flags or the worker's flags. The cache keys on these,
# and fm_lint_run_root records the flags it actually ran beside each root.
fm_lint_root_final_args() {  # <path>
  if fm_lint_known_heavy_root "$1"; then
    fm_lint_no_source_args
    FM_LINT_ROOT_ARGS=("${FM_LINT_NO_SOURCE_ARGS[@]}")
  else
    FM_LINT_ROOT_ARGS=("${FM_LINT_WORKER_ARGS[@]}")
  fi
}

# The memory retry's flags: the worker's flags without source following, plus
# the cross-file codes a no-source pass cannot judge.
fm_lint_no_source_args() {
  local arg
  FM_LINT_NO_SOURCE_ARGS=()
  for arg in "${FM_LINT_WORKER_ARGS[@]}"; do
    [ "$arg" = --external-sources ] || FM_LINT_NO_SOURCE_ARGS+=("$arg")
  done
  [ -z "$LOCAL_NOX_EXCLUDE" ] || FM_LINT_NO_SOURCE_ARGS+=("--exclude=$LOCAL_NOX_EXCLUDE")
}

# Run one selected root, retry memory failures without source following, record
# its lifecycle in the roots log, and append the final diagnostics.
fm_lint_run_root() {  # <index> <path> <output-dir> <shard-index>
  local index=$1 path=$2 output_dir=$3 shard_index=$4
  local root_out="$output_dir/root.$shard_index.$index.out"
  local root_err="$output_dir/root.$shard_index.$index.err"
  local rss_file="$output_dir/root.$shard_index.$index.rss"
  local fallback_out="$output_dir/root.$shard_index.$index.fallback.out"
  local fallback_err="$output_dir/root.$shard_index.$index.fallback.err"
  local fallback_rss="$output_dir/root.$shard_index.$index.fallback.rss"
  local args_file="$output_dir/root.$shard_index.$index.args"
  local start_ms end_ms duration_ms invocation_rc=0 reason rss_kib initial_rc initial_reason
  local fallback_secs
  local final_follow_sources=${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}
  start_ms=$(fm_lint_now_ms)
  if [ -n "${FM_LINT_INTERNAL_ROOTS_LOG:-}" ]; then
    printf 'begin\t%s\t%s\t%s\t%s\t%s\n' \
      "$index" "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-}" "$start_ms" \
      >> "$FM_LINT_INTERNAL_ROOTS_LOG"
  fi
  if [ "${FM_LINT_INTERNAL_PROGRESS:-0}" = 1 ]; then
    printf 'fm-lint: begin %s (shard %s, %s mode)\n' \
      "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-unknown}" >&2
  fi
  if fm_lint_known_heavy_root "$path"; then
    fm_lint_no_source_args
    printf '%s\n' "${FM_LINT_NO_SOURCE_ARGS[@]}" > "$args_file"
    fm_lint_exec_root "$path" "$root_out" "$root_err" "$rss_file" \
      "$FM_LINT_INTERNAL_ROOT_SECS" "${FM_LINT_NO_SOURCE_ARGS[@]}"
    final_follow_sources=0
    invocation_rc=$FM_LINT_LAST_RC
    reason=$(fm_lint_classify_root "$invocation_rc" "$root_err")
    rss_kib=$(fm_lint_root_rss "$rss_file")
    printf 'fm-lint: %s is a known memory-ceiling root; linted without --external-sources' \
      "$path" >> "$output_dir/shard.$shard_index.out"
    if [ "$reason" = ok ]; then
      reason=known-heavy
      printf '; passed with cross-file codes excluded (%s)\n' "$LOCAL_NOX_EXCLUDE" \
        >> "$output_dir/shard.$shard_index.out"
    else
      printf '; reason=%s rc=%s\n' "$reason" "$invocation_rc" \
        >> "$output_dir/shard.$shard_index.out"
    fi
    cat "$root_out" "$root_err" >> "$output_dir/shard.$shard_index.out"
  else
    printf '%s\n' "${FM_LINT_WORKER_ARGS[@]}" > "$args_file"
    fm_lint_exec_root "$path" "$root_out" "$root_err" "$rss_file" \
      "$FM_LINT_INTERNAL_ROOT_SECS" "${FM_LINT_WORKER_ARGS[@]}"
    invocation_rc=$FM_LINT_LAST_RC
    reason=$(fm_lint_classify_root "$invocation_rc" "$root_err")
    initial_rc=$invocation_rc
    initial_reason=$reason
    # The retry spends what is left of this root's one deadline rather than a
    # fresh one, so both attempts together still fit the budget CI sized its job
    # timeout around.
    fallback_secs=$(( (start_ms + FM_LINT_INTERNAL_ROOT_SECS * 1000 - $(fm_lint_now_ms)) / 1000 ))
    if [ "$reason" = memory ] \
      && [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ] \
      && [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] \
      && [ "$fallback_secs" -lt 1 ]; then
      printf 'fm-lint: %s hit the memory ceiling with --external-sources (reason=%s rc=%s); no time left in its %ss deadline to retry without it\n' \
        "$path" "$initial_reason" "$initial_rc" "$FM_LINT_INTERNAL_ROOT_SECS" >> "$output_dir/shard.$shard_index.out"
      rss_kib=$(fm_lint_root_rss "$rss_file")
      cat "$root_out" "$root_err" >> "$output_dir/shard.$shard_index.out"
    elif [ "$reason" = memory ] \
      && [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
      fm_lint_no_source_args
      printf '%s\n' "${FM_LINT_NO_SOURCE_ARGS[@]}" > "$args_file"
      fm_lint_exec_root "$path" "$fallback_out" "$fallback_err" "$fallback_rss" \
        "$fallback_secs" "${FM_LINT_NO_SOURCE_ARGS[@]}"
      final_follow_sources=0
      invocation_rc=$FM_LINT_LAST_RC
      reason=$(fm_lint_classify_root "$invocation_rc" "$fallback_err")
      rss_kib=$(fm_lint_max_root_rss \
        "$(fm_lint_root_rss "$rss_file")" "$(fm_lint_root_rss "$fallback_rss")")
      printf 'fm-lint: %s hit the memory ceiling with --external-sources (reason=%s rc=%s); retried without it' \
        "$path" "$initial_reason" "$initial_rc" >> "$output_dir/shard.$shard_index.out"
      if [ "$reason" = ok ]; then
        reason=memory-fallback
        invocation_rc=0
        printf '; fallback passed with cross-file codes excluded (%s)\n' "$LOCAL_NOX_EXCLUDE" \
          >> "$output_dir/shard.$shard_index.out"
      else
        printf '; fallback reason=%s rc=%s\n' "$reason" "$invocation_rc" \
          >> "$output_dir/shard.$shard_index.out"
      fi
      cat "$fallback_out" "$fallback_err" >> "$output_dir/shard.$shard_index.out"
    else
      rss_kib=$(fm_lint_root_rss "$rss_file")
      cat "$root_out" "$root_err" >> "$output_dir/shard.$shard_index.out"
    fi
  fi
  end_ms=$(fm_lint_now_ms)
  duration_ms=$((end_ms - start_ms))
  if [ -n "${FM_LINT_INTERNAL_ROOTS_LOG:-}" ]; then
    printf 'end\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$index" "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-}" \
      "$start_ms" "$end_ms" "$duration_ms" "$invocation_rc" "$reason" "$rss_kib" "$final_follow_sources" \
      >> "$FM_LINT_INTERNAL_ROOTS_LOG"
  fi
  if [ "${FM_LINT_INTERNAL_PROGRESS:-0}" = 1 ] || { [ "$reason" != ok ] && [ "$reason" != findings ] && [ "$reason" != memory-fallback ] && [ "$reason" != known-heavy ]; }; then
    printf 'fm-lint: end %s reason=%s rc=%s duration_ms=%s rss_kib=%s\n' \
      "$path" "$reason" "$invocation_rc" "$duration_ms" "$rss_kib" >&2
  fi
  return "$invocation_rc"
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab entry index path output invocation_rc rc=0
  local -a root_entries
  root_entries=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    root_entries+=("$index	$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#root_entries[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    fm_lint_build_worker_args
    : > "$output.out"
    for entry in "${root_entries[@]}"; do
      index=${entry%%"$tab"*}
      path=${entry#*"$tab"}
      invocation_rc=0
      fm_lint_run_root "$index" "$path" "$output_dir" "$shard_index" || invocation_rc=$?
      if [ "$rc" -eq 0 ] && [ "$invocation_rc" -ne 0 ]; then
        rc=$invocation_rc
      fi
    done
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

# Private per-root payload mode used only by the bounded runner above: apply
# the per-process address-space limit (a positive KiB count), then exec
# /usr/bin/time for the per-root peak-RSS record when it is available, else the
# tool itself. A limit the host cannot apply exits 97 so the parent reports
# limit-unavailable instead of running uncapped.
if [ "${1:-}" = "--internal-root" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-root is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -ge 4 ] || exit 2
  internal_rss_file=$2
  internal_memory_kib=$3
  shift 3
  case "$internal_memory_kib" in
    ''|0*|*[!0-9]*)
      printf 'fm-lint.sh: --internal-root memory limit must be a positive KiB count, got %s\n' \
        "$internal_memory_kib" >&2
      exit 2
      ;;
  esac
  ulimit -v "$internal_memory_kib" 2>/dev/null || {
    printf 'fm-lint.sh: per-root memory limit %s KiB is not enforceable on this host\n' \
      "$internal_memory_kib" >&2
    exit 97
  }
  # The exec boundary: ShellCheck never inherits ambient options.
  unset SHELLCHECK_OPTS
  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec /usr/bin/time -l -o "$internal_rss_file" "$@"
    fi
    exec /usr/bin/time -f 'max_rss_kib=%M' -o "$internal_rss_file" "$@"
  fi
  exec "$@"
fi

# Private bounded-run mode used only by the per-root runner above: the caller
# has already moved this process into its own group, so re-enter through SELF
# keeps the watchdog out of the worker's killable group while resolving the
# shared fm_exec_timed implementation through the same source path.
if [ "${1:-}" = "--internal-timed" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-timed is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -ge 4 ] || exit 2
  declare -F fm_exec_timed >/dev/null 2>&1 || {
    printf 'fm-lint.sh: fm-timeout-lib.sh is required for bounded runs.\n' >&2
    exit 127
  }
  fm_exec_timed "$2" "$3" "${@:4}"
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

# Backend adapters belong behind tasks-axi. Keep direct Beads CLI invocations
# out of firstmate's core scripts so every configured backend follows the same
# lifecycle path.
fm_lint_run_backend_purity() {
  local findings path canonical
  local -a purity_roots
  purity_roots=()
  if [ "$EXPLICIT_PATHS" -eq 0 ]; then
    purity_roots=(bin/*.sh bin/backends/*.sh)
  else
    for path in "${ROOTS[@]}"; do
      [ -f "$path" ] || continue
      # shellcheck disable=SC2016 # Perl, not the shell, expands $ARGV.
      canonical=$("$PERL_BIN" -MCwd=realpath -e '
        my $resolved = realpath($ARGV[0]);
        exit 1 unless defined $resolved;
        print $resolved;
      ' "$path" 2>/dev/null) || continue
      case "$canonical" in
        "$ROOT"/bin/*.sh|"$ROOT"/bin/backends/*.sh)
          purity_roots+=("$canonical")
          ;;
      esac
    done
  fi
  [ "${#purity_roots[@]}" -gt 0 ] || return 0
  findings=$(LC_ALL=C awk '
    function hex_value(character) {
      return index("0123456789abcdef", tolower(character)) - 1
    }
    function ansi_number(digits, base,    i, value) {
      value=0
      for (i=1; i <= length(digits); i++) value=value * base + hex_value(substr(digits, i, 1))
      return value
    }
    # Non-printable and non-ASCII bytes can never spell the bd command, so a
    # placeholder keeps them from colliding into it.
    function ansi_character(value) {
      if (value < 32 || value > 126) return "?"
      return sprintf("%c", value)
    }
    function invokes_bd(segment) {
      sub(/^[[:space:]]+/, "", segment)
      while (1) {
        previous=segment
        sub(/^(if|then|elif|else|while|until|do)[[:space:]]+/, "", segment)
        sub(/^![[:space:]]+/, "", segment)
        sub(/^(command|exec)[[:space:]]+/, "", segment)
        sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
        if (segment ~ /^env[[:space:]]+/) {
          sub(/^env[[:space:]]+/, "", segment)
          while (1) {
            if (segment ~ /^--[[:space:]]+/) {
              sub(/^--[[:space:]]+/, "", segment)
              break
            }
            if (segment ~ /^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/) {
              sub(/^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/) {
              sub(/^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/) {
              sub(/^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/) {
              sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            break
          }
        }
        if (segment == previous) break
      }
      command_word=""
      quote=""
      ansi=0
      for (position=1; position <= length(segment); position++) {
        character=substr(segment, position, 1)
        if (quote == "") {
          if (character ~ /[[:space:]]/) break
          if (character == "$" && position < length(segment)) {
            next_character=substr(segment, position + 1, 1)
            if (next_character == "\"" || next_character == sprintf("%c", 39)) {
              position++
              quote=next_character
              ansi=(next_character == sprintf("%c", 39)) ? 1 : 0
              continue
            }
          }
          if (character == "\"" || character == sprintf("%c", 39)) {
            quote=character
            ansi=0
            continue
          }
          if (character == "\\") {
            position++
            if (position > length(segment)) return 0
            character=substr(segment, position, 1)
          }
          command_word=command_word character
          continue
        }
        if (character == quote) {
          quote=""
          ansi=0
          continue
        }
        if (character == "\\" && (quote == "\"" || ansi)) {
          position++
          if (position > length(segment)) return 0
          escape=substr(segment, position, 1)
          if (ansi) {
            # ANSI-C quoting decodes escapes, so an encoded spelling of the
            # command still runs bd and must be decoded here to be caught.
            value=-1
            if (escape == "x" || escape == "u" || escape == "U") {
              max_digits=2
              if (escape == "u") max_digits=4
              if (escape == "U") max_digits=8
              digits=""
              while (length(digits) < max_digits && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-9A-Fa-f]/) break
                digits=digits digit
                position++
              }
              if (digits == "") {
                # An escape prefix with no digits yields the prefix character.
                command_word=command_word escape
                continue
              }
              value=ansi_number(digits, 16)
            } else if (escape ~ /[0-7]/) {
              digits=escape
              while (length(digits) < 3 && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-7]/) break
                digits=digits digit
                position++
              }
              value=ansi_number(digits, 8)
            }
            if (value >= 0) {
              if (value == 0) {
                # NUL truncates the bash word.
                quote=""
                break
              }
              command_word=command_word ansi_character(value)
              continue
            }
            if (escape == "c") {
              # Control characters can never spell the bd command.
              if (position < length(segment)) position++
              command_word=command_word "?"
              continue
            }
            if (escape ~ /^[abeEfnrtv]$/) {
              command_word=command_word "?"
              continue
            }
            # Remaining ANSI-C escapes keep their character, and bash drops
            # the backslash before any other character.
            command_word=command_word escape
            continue
          }
          character=escape
        }
        command_word=command_word character
      }
      if (quote != "") return 0
      return command_word ~ /(^|\/)bd$/
    }
    function split_commands(line, segments,   position, character, quote, current, count) {
      delete segments
      count=0
      current=""
      quote=""
      for (position=1; position <= length(line); position++) {
        character=substr(line, position, 1)
        if (quote != "") {
          current=current character
          if (character == quote) {
            quote=""
          } else if (quote == "\"" && character == "\\") {
            position++
            if (position <= length(line)) current=current substr(line, position, 1)
          }
          continue
        }
        if (character == "\\") {
          current=current character
          position++
          if (position <= length(line)) current=current substr(line, position, 1)
          continue
        }
        if (character == "\"" || character == sprintf("%c", 39)) {
          quote=character
          current=current character
          continue
        }
        if (character ~ /[();|&{}]/) {
          segments[++count]=current
          current=""
          continue
        }
        current=current character
      }
      if (quote != "") return split(line, segments, /[();|&{}]+/)
      segments[++count]=current
      return count
    }
    /^[[:space:]]*#/ { next }
    {
      count=split_commands($0, segments)
      for (i=1; i<=count; i++) {
        if (invokes_bd(segments[i])) {
          print FILENAME ":" FNR ": direct Beads CLI invocation bypasses tasks-axi"
          break
        }
      }
    }
  ' "${purity_roots[@]}")
  [ -z "$findings" ] || {
    printf '%s\n' "$findings" >&2
    return 1
  }
}

JOBS=${FM_LINT_JOBS:-}
TELEMETRY=${FM_LINT_TELEMETRY:-}
FAST=0
ANALYSIS_MODE=full
PARTITION=
PARTITION_REQUESTED=0
FORCE_CHANGED=0
LIST_FILES=0
NO_CACHE=0
AUDIT_CACHE=
AUDIT_RECORDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --partition)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --partition requires <k>of%s.\n' "$FM_LINT_CI_PARTITIONS" >&2; exit 2; }
      PARTITION=$2
      PARTITION_REQUESTED=1
      shift 2
      ;;
    --partition=*)
      PARTITION=${1#*=}
      PARTITION_REQUESTED=1
      shift
      ;;
    --changed)
      FORCE_CHANGED=1
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --audit-cache)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --audit-cache requires a directory.\n' >&2; exit 2; }
      AUDIT_CACHE=$2
      NO_CACHE=1
      shift 2
      ;;
    --audit-record)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --audit-record requires a cache sidecar path.\n' >&2; exit 2; }
      AUDIT_RECORDS+=("$2")
      NO_CACHE=1
      shift 2
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "${FM_LINT_CACHE_DIR:-/}" in
  /*) ;;
  *) printf 'fm-lint.sh: FM_LINT_CACHE_DIR must be an absolute path, got %s.\n' "$FM_LINT_CACHE_DIR" >&2; exit 2 ;;
esac
if { [ -n "$AUDIT_CACHE" ] || [ "${#AUDIT_RECORDS[@]}" -gt 0 ]; } \
  && ! declare -F fm_lint_cache_audit >/dev/null 2>&1; then
  printf 'fm-lint.sh: the cache audit needs bin/fm-lint-cache-lib.sh beside fm-lint.sh.\n' >&2
  exit 2
fi

JOBS_EXPLICIT=0
if [ -z "$JOBS" ]; then
  if [ -n "$PARTITION" ]; then JOBS=1; else JOBS=2; fi
else
  JOBS_EXPLICIT=1
fi
case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

fm_lint_partition_refuse() {
  printf 'fm-lint.sh: --partition must be <k>of%s, got %s.\n' "$FM_LINT_CI_PARTITIONS" "$1" >&2
  exit 2
}

case "$PARTITION" in
  '')
    if [ "$PARTITION_REQUESTED" -eq 1 ]; then
      printf 'fm-lint.sh: --partition requires <k>of%s.\n' "$FM_LINT_CI_PARTITIONS" >&2
      exit 2
    fi
    ;;
  *of*)
    partition_index=${PARTITION%%of*}
    partition_count=${PARTITION##*of}
    case "$partition_index" in ''|*[!0-9]*) fm_lint_partition_refuse "$PARTITION" ;; esac
    case "$partition_count" in ''|*[!0-9]*) fm_lint_partition_refuse "$PARTITION" ;; esac
    if [ "$partition_count" -ne "$FM_LINT_CI_PARTITIONS" ]; then
      printf 'fm-lint.sh: --partition asks for %s canonical partitions but this script owns %s, got %s.\n' \
        "$partition_count" "$FM_LINT_CI_PARTITIONS" "$PARTITION" >&2
      exit 2
    fi
    if [ "$partition_index" -lt 1 ] || [ "$partition_index" -gt "$partition_count" ]; then
      fm_lint_partition_refuse "$PARTITION"
    fi
    if [ "$FAST" -eq 1 ] || [ "$#" -gt 0 ]; then
      printf 'fm-lint.sh: --partition cannot combine with --fast or explicit paths.\n' >&2
      exit 2
    fi
    ;;
  *) fm_lint_partition_refuse "$PARTITION" ;;
esac

# A local run is any run outside the hosted workflow contract (GITHUB_ACTIONS
# with required bounds, as ci.yml sets them; a bare CI=true does not count): a
# developer lint, the no-mistakes gate, or a worker's own lint. Local runs
# never take the full-set upgrade or default to the full canonical set, apply
# the per-root bounds when the host can, and run workers at low priority.
LOCAL_RUN=1
if [ "${GITHUB_ACTIONS:-}" = true ] && [ "${FM_LINT_REQUIRE_BOUNDS:-0}" = 1 ]; then
  LOCAL_RUN=0
fi
if [ "$FAST" -eq 1 ] && [ "$LOCAL_RUN" -eq 0 ]; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" (a --changed or local run then refuses).
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_MODE=0
CANONICAL_SET=0
EXPLICIT_PATHS=0
FOLLOW_SOURCES=1
EXCLUDE_CODES=
# A failed diff (a corrupt index, say) must never read as an empty changed set
# that skips every root, nor fall back to the canonical set: it refuses.
# Both captures live in one private directory whose scoped cleanup covers exit
# and catchable signals until the later worker traps take over; Git runs as a
# waited child so a trapped signal interrupts the wait instead of queueing.
DIFF_CAPTURE_DIR=
DIFF_CAPTURE_PID=
# shellcheck disable=SC2329 # Registered by the collector's scoped traps.
fm_lint_diff_capture_cleanup() {
  [ -z "$DIFF_CAPTURE_PID" ] || kill -TERM "$DIFF_CAPTURE_PID" 2>/dev/null || true
  [ -z "$DIFF_CAPTURE_DIR" ] || rm -rf "$DIFF_CAPTURE_DIR"
  DIFF_CAPTURE_PID=
  DIFF_CAPTURE_DIR=
}
fm_lint_collect_changed_roots() {  # <merge-base>
  local merge_base=$1 changed_path diff_file diff_rc=0
  trap fm_lint_diff_capture_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  DIFF_CAPTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint-diff.XXXXXX") || exit 1
  diff_file="$DIFF_CAPTURE_DIR/names"
  git diff --name-only --diff-filter=ACMR -z "$merge_base" -- >"$diff_file" 2>"$diff_file.err" &
  DIFF_CAPTURE_PID=$!
  wait "$DIFF_CAPTURE_PID" || diff_rc=$?
  DIFF_CAPTURE_PID=
  if [ "$diff_rc" -ne 0 ]; then
    printf 'fm-lint.sh: git diff against merge-base %s failed (exit %s), so the changed lint targets are unknown; refusing to report an empty lint. Repair the repository state (see git status) and rerun.\n' \
      "$merge_base" "$diff_rc" >&2
    sed 's/^/fm-lint.sh: git: /' "$diff_file.err" >&2
    exit 2
  fi
  diff_rc=0
  LC_ALL=C sort -z "$diff_file" >"$diff_file.sorted" 2>"$diff_file.err" || diff_rc=$?
  if [ "$diff_rc" -ne 0 ]; then
    printf 'fm-lint.sh: sorting the changed paths failed (exit %s), so the changed lint targets are unknown; refusing to report an empty lint.\n' \
      "$diff_rc" >&2
    sed 's/^/fm-lint.sh: sort: /' "$diff_file.err" >&2
    exit 2
  fi
  ROOTS=()
  while IFS= read -r -d '' changed_path; do
    fm_lint_is_canonical_root "$changed_path" || continue
    [ -f "$changed_path" ] || continue
    ROOTS+=("$changed_path")
  done < "$diff_file.sorted"
  fm_lint_diff_capture_cleanup
  trap - EXIT HUP INT TERM
}

# git diff --name-only drops a rename's old path, and --diff-filter=ACMR drops
# deletions, so both upgrade checks walk name-status ACDMR and treat a rename
# or copy as both of its paths.
fm_lint_changed_paths() {  # <merge-base>
  local merge_base=$1 status p1 p2
  while IFS=$'\t' read -r status p1 p2; do
    [ -n "$status" ] || continue
    case "$status" in
      R*|C*)
        [ -n "$p1" ] && printf '%s\n' "$p1"
        [ -n "$p2" ] && printf '%s\n' "$p2"
        ;;
      *)
        [ -n "$p1" ] && printf '%s\n' "$p1"
        ;;
    esac
  done < <(git diff --name-status --diff-filter=ACDMR "$merge_base" -- 2>/dev/null)
}

# Changing the lint owner, its pinned installers, or the bounds watchdog is a
# definition change: a PR that only lists those files still needs the full
# canonical, source-aware gate rather than a changed-file subset. A delete or
# rename of any of those paths counts, including the old name of a rename.
# The same list is part of every cache key, so editing any of them misses every
# cached root.
FM_LINT_DEFINITION_FILES=(
  bin/fm-lint.sh bin/fm-lint-cache-lib.sh bin/fm-lint-workflows.sh
  bin/fm-install-shellcheck.sh bin/fm-install-actionlint.sh bin/fm-timeout-lib.sh
)
fm_lint_is_definition_path() {  # <path>
  local definition
  for definition in "${FM_LINT_DEFINITION_FILES[@]}"; do
    [ "$1" != "$definition" ] || return 0
  done
  return 1
}

fm_lint_definition_changed() {  # <merge-base>
  local merge_base=$1 path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    fm_lint_is_definition_path "$path" && return 0
  done < <(fm_lint_changed_paths "$merge_base")
  return 1
}

# A changed canonical file that another canonical script sources (via a
# `# shellcheck source=` directive) can introduce a ShellCheck finding only in
# that unchanged consumer. Changed-file lint would miss it and leave main's
# full gate red, so those PRs take the full set like a lint-definition change.
# Resolve targets lexically so a deleted or renamed-away helper still matches;
# walk the merge-base source graph when git can list that tree.
fm_lint_resolve_source_target() {  # <consumer> <target>
  local consumer=$1 target=$2 dir
  case "$target" in
    ''|/dev/null|/*) return 1 ;;
  esac
  case "$target" in
    */*)
      printf '%s\n' "$target"
      return 0
      ;;
  esac
  dir=$(dirname "$consumer")
  printf '%s/%s\n' "$dir" "$target"
}

fm_lint_source_targets_from_text() {
  awk '
    /^[[:space:]]*# shellcheck source=/ {
      target=$0
      sub(/^[[:space:]]*# shellcheck source=/, "", target)
      sub(/[[:space:]].*$/, "", target)
      print target
    }
  '
}

fm_lint_sourced_helper_changed() {  # <merge-base>
  local merge_base=$1 consumer target resolved changed consumers body
  changed=$(fm_lint_changed_paths "$merge_base") || return 1
  [ -n "$changed" ] || return 1
  consumers=$(git ls-tree -r --name-only "$merge_base" 2>/dev/null \
    | grep -E '^(bin/[^/]+\.sh|bin/backends/[^/]+\.sh|tests/[^/]+\.sh)$' || true)
  if [ -z "$consumers" ]; then
    consumers=$(printf '%s\n' bin/*.sh bin/backends/*.sh tests/*.sh)
  fi
  while IFS= read -r consumer; do
    [ -n "$consumer" ] || continue
    if ! body=$(git show "$merge_base:$consumer" 2>/dev/null); then
      [ -f "$consumer" ] || continue
      body=$(cat "$consumer")
    fi
    while IFS= read -r target; do
      resolved=$(fm_lint_resolve_source_target "$consumer" "$target") || continue
      [ "$resolved" != "$consumer" ] || continue
      printf '%s\n' "$changed" | grep -Fxq "$resolved" || continue
      return 0
    done < <(printf '%s\n' "$body" | fm_lint_source_targets_from_text)
  done <<EOF
$consumers
EOF
  return 1
}

if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  merge_base=
  want_changed=0
  if [ "$FORCE_CHANGED" -eq 1 ] || { [ -z "$PARTITION" ] && [ "$LOCAL_RUN" -eq 1 ]; }; then
    want_changed=1
  fi
  if [ "$want_changed" -eq 1 ]; then
    no_changed_set=
    if ! command -v git >/dev/null 2>&1 \
      || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      no_changed_set='not inside a Git work tree'
    else
      base_ref=$(fm_lint_changed_base_ref) || base_ref=
      [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
      [ -n "$merge_base" ] || no_changed_set='no merge-base against origin/main or main'
    fi
    if [ -n "$merge_base" ]; then
      # Only hosted CI's --changed run upgrades; a local run keeps its changed
      # files because the full source-following set exhausts dev-host memory.
      full_lint=0
      may_upgrade=0
      [ "$FORCE_CHANGED" -eq 0 ] || [ "$LOCAL_RUN" -eq 1 ] || may_upgrade=1
      if [ "$may_upgrade" -eq 1 ] && fm_lint_definition_changed "$merge_base"; then
        printf 'fm-lint.sh: lint definition files changed; using full canonical lint\n' >&2
        full_lint=1
      elif [ "$may_upgrade" -eq 1 ] && fm_lint_sourced_helper_changed "$merge_base"; then
        printf 'fm-lint.sh: a sourced helper changed; using full canonical lint\n' >&2
        full_lint=1
      fi
    elif [ "$FORCE_CHANGED" -eq 1 ]; then
      printf 'fm-lint.sh: --changed needs a merge-base against origin/main or main.\n' >&2
      exit 2
    else
      printf 'fm-lint.sh: cannot compute a local changed-file set (%s); refusing the full canonical lint locally. Pass explicit paths, or lint the full set in a capped sandbox (for example a Boat sandbox started with --no-env, one --partition at a time) or in CI.\n' \
        "$no_changed_set" >&2
      exit 2
    fi
  fi

  if [ "$full_lint" -eq 1 ]; then
    CANONICAL_SET=1
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    fm_lint_collect_changed_roots "$merge_base"
  fi
fi
if [ "$CHANGED_MODE" -eq 1 ] && [ "$FAST" -eq 0 ] && [ "$FORCE_CHANGED" -eq 0 ]; then
  FOLLOW_SOURCES=0
  EXCLUDE_CODES=$LOCAL_NOX_EXCLUDE
  ANALYSIS_MODE=local
fi
# Measured per-root source-aware lint durations in milliseconds ("<path> <ms>"
# per line): the median completed sample (rc 0, reason ok or memory-fallback)
# in the *.roots.tsv sidecars of hosted CI runs 45668223859, 45544062045,
# 45529459572, and 45532696616 (docs/fm-test-portable-shards.md "Lint
# partitions and end-to-end latency"). A known-heavy root's value is that
# median scaled by its sandboxed no-source share of both attempts, until
# telemetry records it running alone. They weight only the cross-runner partition
# packing; coverage never depends on them. A canonical root missing here packs
# on FM_LINT_DEFAULT_ROOT_WEIGHT_MS.
fm_lint_root_duration_hints() {
  cat <<'EOF'
bin/backends/cmux.sh 1622
bin/backends/hc.sh 3154
bin/backends/herdr.sh 12071
bin/backends/orca.sh 1524
bin/backends/paseo.sh 10245
bin/backends/rex.sh 11949
bin/backends/t3code.sh 1649
bin/backends/tern.sh 3806
bin/backends/tmux.sh 4254
bin/backends/zellij.sh 1774
bin/fm-afk-contract.sh 2724
bin/fm-afk-launch.sh 13476
bin/fm-afk-return.sh 18585
bin/fm-afk-start.sh 6734
bin/fm-agent-process-lib.sh 896
bin/fm-agy-trust.sh 170
bin/fm-approval-failover.sh 10465
bin/fm-arm-pretool-check.sh 124
bin/fm-backend-hometag-lib.sh 70
bin/fm-backend.sh 874
bin/fm-backlog-handoff.sh 50686
bin/fm-backlog-receive.sh 8618
bin/fm-backlog-transition-lib.sh 3056
bin/fm-bearings-board.sh 220
bin/fm-bearings-snapshot.sh 523
bin/fm-bootstrap.sh 49404
bin/fm-branch-outcome.sh 10292
bin/fm-branch-prompt.sh 72
bin/fm-branch-report.sh 12074
bin/fm-brief-heading-lib.sh 72
bin/fm-brief.sh 12474
bin/fm-busy-event.sh 950
bin/fm-busy-lib.sh 624
bin/fm-calendar-lib.sh 74
bin/fm-capacity.sh 12197
bin/fm-captain-hold.sh 21436
bin/fm-cd-pretool-check.sh 122
bin/fm-check-lib.sh 122
bin/fm-check-register.sh 2053
bin/fm-check-unregister.sh 1572
bin/fm-ci-budget-warn.sh 96
bin/fm-classify-lib.sh 5486
bin/fm-claude-account-quota.sh 576
bin/fm-claude-stop-autoarm.sh 10070
bin/fm-claude-trust.sh 324
bin/fm-codex-stop-park.sh 7786
bin/fm-composer-lib.sh 1247
bin/fm-config-inherit-lib.sh 1474
bin/fm-config-push.sh 11974
bin/fm-contributions.sh 12099
bin/fm-control-lib.sh 225
bin/fm-control.sh 21242
bin/fm-cortex-plugin.sh 98
bin/fm-credential-source-lib.sh 220
bin/fm-crew-state.sh 20695
bin/fm-cursor-lib.sh 296
bin/fm-decision-hold.sh 170
bin/fm-devin-config.sh 76
bin/fm-dispatch-resolve.sh 8490
bin/fm-doc-audience-check.sh 70
bin/fm-dod-lib.sh 7510
bin/fm-ensure-agents-md.sh 148
bin/fm-env-lib.sh 74
bin/fm-exclude-tools-lib.sh 69
bin/fm-extension.sh 70
bin/fm-external-review-lib.sh 2028
bin/fm-ff-lib.sh 648
bin/fm-fleet-ledger.sh 10644
bin/fm-fleet-snapshot.sh 13579
bin/fm-fleet-sync.sh 422
bin/fm-fleet-view.sh 72
bin/fm-forge-detect.sh 69
bin/fm-gate-refuse-lib.sh 122
bin/fm-gemini-lib.sh 70
bin/fm-git-push-guard.sh 1948
bin/fm-git-strip-ai-trailers.sh 170
bin/fm-guard.sh 7036
bin/fm-harness.sh 746
bin/fm-hc-ci-cleanup.sh 147
bin/fm-hc-lab.sh 274
bin/fm-herdr-ci-cleanup.sh 69
bin/fm-herdr-groups.sh 11844
bin/fm-herdr-lab.sh 499
bin/fm-herdr-session-cleanup.sh 12324
bin/fm-hermes-hook.sh 69
bin/fm-hermes-lib.sh 120
bin/fm-hermes-process-lib.sh 72
bin/fm-hold-reason-lib.sh 75
bin/fm-home-seed.sh 10695
bin/fm-home-summary-refresh.sh 7136
bin/fm-hook-host-lib.sh 70
bin/fm-host-mirror.sh 8616
bin/fm-inactive-reconcile.sh 26000
bin/fm-inbox.sh 8988
bin/fm-install-actionlint.sh 69
bin/fm-install-hc.sh 74
bin/fm-install-herdr.sh 72
bin/fm-install-shellcheck.sh 69
bin/fm-install-treehouse.sh 99
bin/fm-jev-mem-guard.sh 70
bin/fm-kimi-delivery-lib.sh 68
bin/fm-kimi-trust-lib.sh 68
bin/fm-kimi-turnend-hook.sh 72
bin/fm-lab-home.sh 169
bin/fm-landed-lib.sh 74
bin/fm-lane-vitals-lib.sh 220
bin/fm-launch-mise-env-lib.sh 70
bin/fm-lavish-url.sh 270
bin/fm-lease-lib.sh 370
bin/fm-lease.sh 7312
bin/fm-line-cap-lib.sh 70
bin/fm-lint-workflows.sh 94
bin/fm-lint.sh 1326
bin/fm-live-lab.sh 622
bin/fm-local-handoff-lib.sh 822
bin/fm-local-handoff.sh 14255
bin/fm-lock-lib.sh 70
bin/fm-lock.sh 8540
bin/fm-mail-check.sh 2352
bin/fm-mail.sh 19393
bin/fm-marker-lib.sh 270
bin/fm-merge-authority-lib.sh 4880
bin/fm-merge-local.sh 23046
bin/fm-merge-outcome-lib.sh 11795
bin/fm-nm-respond.sh 72
bin/fm-nm-run-lib.sh 324
bin/fm-omp-process-lib.sh 72
bin/fm-omp-profile-lib.sh 69
bin/fm-on.sh 348
bin/fm-operational-input.sh 271
bin/fm-osc7501.sh 5913
bin/fm-pane-question-lib.sh 3878
bin/fm-parent-channel-lib.sh 2728
bin/fm-park.sh 14974
bin/fm-path-lib.sh 72
bin/fm-peek.sh 870
bin/fm-pending-reply-lib.sh 20340
bin/fm-pipeline-spend.sh 2378
bin/fm-polytoken-lib.sh 370
bin/fm-pr-check.sh 20741
bin/fm-pr-health.sh 9842
bin/fm-pr-lib.sh 1626
bin/fm-pr-merge.sh 45498
bin/fm-pr-poll.sh 270
bin/fm-pr-review-snapshot.sh 1851
bin/fm-pr-review.sh 2500
bin/fm-pr-reviewers.sh 1598
bin/fm-pr-risk.sh 99
bin/fm-pr-state.sh 1928
bin/fm-primary-scope-lib.sh 74
bin/fm-procevent-lavish.sh 12526
bin/fm-procevent-lib.sh 946
bin/fm-procevent-quota.sh 10318
bin/fm-procevent-remote-reply.sh 37206
bin/fm-procevent-when.sh 10769
bin/fm-procevent.sh 16511
bin/fm-project-capacity-lib.sh 120
bin/fm-project-mode.sh 120
bin/fm-project-origin-lib.sh 120
bin/fm-promote.sh 37426
bin/fm-public-followup-collect.sh 13250
bin/fm-public-followup-emit.sh 13421
bin/fm-public-followup-lib.sh 11924
bin/fm-public-followup.sh 18112
bin/fm-push-transition-lib.sh 11900
bin/fm-quota-axi-lib.sh 124
bin/fm-quota-choose.sh 320
bin/fm-record-export.sh 8016
bin/fm-record-hygiene-lib.sh 8492
bin/fm-remote-delta-read.sh 200
bin/fm-remote-doctor.sh 4004
bin/fm-remote-entrypoint.sh 1753
bin/fm-remote-file.sh 7060
bin/fm-remote-herdr-guard.sh 1576
bin/fm-remote-herdr-identity-lib.sh 122
bin/fm-remote-herdr-owner-lib.sh 150
bin/fm-remote-home-provision.sh 8292
bin/fm-remote-home-seed.sh 7484
bin/fm-remote-inherit-push.sh 2050
bin/fm-remote-inherit.sh 9718
bin/fm-remote-job-lib.sh 1426
bin/fm-remote-job-reap-orphans.sh 1398
bin/fm-remote-job-worker.sh 2777
bin/fm-remote-readiness-lib.sh 72
bin/fm-remote-secondmate-control.sh 22849
bin/fm-remote-secondmate-relaunch.sh 9520
bin/fm-review-check.sh 18712
bin/fm-review-diff.sh 9764
bin/fm-rex-marks.sh 13526
bin/fm-role-lib.sh 270
bin/fm-role.sh 348
bin/fm-secondmate-charter-lib.sh 72
bin/fm-secondmate-liveness-lib.sh 8388
bin/fm-secondmate-nudge-lib.sh 120
bin/fm-secondmate-parent-lib.sh 69
bin/fm-secondmate-reconcile.sh 8440
bin/fm-secondmate-registry-lib.sh 220
bin/fm-secondmate-report.sh 24600
bin/fm-secondmate-restart-lib.sh 25582
bin/fm-secondmate-restart.sh 36171
bin/fm-secondmate-sleep-lib.sh 70
bin/fm-secondmate-sleep.sh 36530
bin/fm-send.sh 31166
bin/fm-session-lock-lib.sh 722
bin/fm-session-start.sh 26854
bin/fm-sessionstart-agy.sh 74
bin/fm-sessionstart-cursor.sh 72
bin/fm-sessionstart-nudge.sh 1401
bin/fm-sessionstart-run.sh 922
bin/fm-spawn.sh 14413
bin/fm-startup-growth-check.sh 2174
bin/fm-startup-memory-budget-lib.sh 146
bin/fm-startup-memory-budget.sh 199
bin/fm-startup-network.sh 8915
bin/fm-stow-cascade.sh 1874
bin/fm-stow-guard.sh 170
bin/fm-subagent-pretool-check.sh 122
bin/fm-supervise-daemon.sh 20842
bin/fm-supervision-engine-lib.sh 247
bin/fm-supervision-handoff.sh 11349
bin/fm-supervision-host.sh 14776
bin/fm-supervision-instructions.sh 446
bin/fm-supervision-lib.sh 70
bin/fm-supervisor-target-lib.sh 70
bin/fm-t3-answer.sh 973
bin/fm-t3code-codex-env.sh 72
bin/fm-tangle-lib.sh 74
bin/fm-task-budget-lib.sh 70
bin/fm-task-inbox-lib.sh 400
bin/fm-tasks-axi-lib.sh 270
bin/fm-tasks-axi.sh 3228
bin/fm-teardown-procevent-lib.sh 70
bin/fm-teardown.sh 3528
bin/fm-test-isolation-proof.sh 270
bin/fm-test-linux.sh 120
bin/fm-test-run.sh 1826
bin/fm-test-tap-verify.sh 96
bin/fm-timeout-lib.sh 199
bin/fm-timing-lib.sh 97
bin/fm-tmux-lib.sh 2050
bin/fm-tool-update-check.sh 2500
bin/fm-trace-context-lib.sh 120
bin/fm-transition-lib.sh 96
bin/fm-turnend-guard-agy.sh 9145
bin/fm-turnend-guard-cursor.sh 8290
bin/fm-turnend-guard-grok.sh 348
bin/fm-turnend-guard.sh 8466
bin/fm-update.sh 23521
bin/fm-usage-warner.sh 9943
bin/fm-vendor-auth-probe.sh 221
bin/fm-wake-drain.sh 15028
bin/fm-wake-grant.sh 7590
bin/fm-wake-lib.sh 6108
bin/fm-warm-compact-lib.sh 120
bin/fm-watch-arm.sh 7638
bin/fm-watch-checkpoint.sh 370
bin/fm-watch-key-lib.sh 70
bin/fm-watch.sh 3938
bin/fm-worker-account-lib.sh 398
bin/fm-x-dismiss.sh 4630
bin/fm-x-followup.sh 12426
bin/fm-x-lib.sh 4380
bin/fm-x-link.sh 15406
bin/fm-x-poll.sh 15958
bin/fm-x-reply.sh 4806
tests/captain-hold-helpers.sh 198
tests/cmux-test-safety.sh 74
tests/fixtures.sh 722
tests/fm-afk-contract.test.sh 1374
tests/fm-afk-inject-e2e.test.sh 200
tests/fm-afk-inject-herdr-e2e.test.sh 272
tests/fm-afk-launch.test.sh 21897
tests/fm-afk-pi-herdr-return-e2e.test.sh 998
tests/fm-afk-return.test.sh 4056
tests/fm-agents-md-size.test.sh 721
tests/fm-agy-harness.test.sh 1348
tests/fm-agy-primary-live-e2e.test.sh 796
tests/fm-agy-primary.test.sh 1200
tests/fm-agy-signals-live-e2e.test.sh 822
tests/fm-approval-failover.test.sh 3052
tests/fm-arm-pretool-check.test.sh 996
tests/fm-ask-user-authority.test.sh 722
tests/fm-assertions.test.sh 799
tests/fm-backend-autodetect-smoke.test.sh 172
tests/fm-backend-cmux-smoke.test.sh 170
tests/fm-backend-cmux.test.sh 6284
tests/fm-backend-hc-appdetect-smoke.test.sh 922
tests/fm-backend-hc-liveness-live-e2e.test.sh 847
tests/fm-backend-hc-smoke.test.sh 998
tests/fm-backend-hc.test.sh 1076
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh 948
tests/fm-backend-herdr-eventwait-smoke.test.sh 170
tests/fm-backend-herdr-focus-flash-e2e.test.sh 324
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh 450
tests/fm-backend-herdr-presentation-e2e.test.sh 3030
tests/fm-backend-herdr-prune-safety-e2e.test.sh 170
tests/fm-backend-herdr-respawn-idem-e2e.test.sh 146
tests/fm-backend-herdr-server-eof.test.sh 220
tests/fm-backend-herdr-smoke.test.sh 270
tests/fm-backend-herdr-stale-active-tab-e2e.test.sh 98
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh 220
tests/fm-backend-herdr.test.sh 41834
tests/fm-backend-orca.test.sh 1823
tests/fm-backend-paseo-smoke.test.sh 170
tests/fm-backend-paseo.test.sh 13496
tests/fm-backend-rex-composer-live-e2e.test.sh 1052
tests/fm-backend-rex-eventwait-smoke.test.sh 321
tests/fm-backend-rex-smoke.test.sh 325
tests/fm-backend-rex.test.sh 1648
tests/fm-backend-t3code-live-e2e.test.sh 696
tests/fm-backend-t3code-pr-tools-live-e2e.test.sh 746
tests/fm-backend-t3code.test.sh 3428
tests/fm-backend-tern-smoke.test.sh 224
tests/fm-backend-tern.test.sh 11472
tests/fm-backend-tmux-smoke.test.sh 220
tests/fm-backend-zellij-smoke.test.sh 172
tests/fm-backend-zellij.test.sh 6186
tests/fm-backend.test.sh 2000
tests/fm-backlog-atomicity.test.sh 10642
tests/fm-backlog-handoff.test.sh 1849
tests/fm-backlog-read-bound.test.sh 872
tests/fm-bearings-board-lavish-live-e2e.test.sh 849
tests/fm-bearings-board-render.test.sh 1026
tests/fm-bearings-board.test.sh 1223
tests/fm-bearings-snapshot.test.sh 3251
tests/fm-bootstrap-diagnostics.test.sh 772
tests/fm-bootstrap-network-parallel.test.sh 1122
tests/fm-bootstrap.test.sh 2478
tests/fm-branch-supervision.test.sh 2225
tests/fm-brief-tdd.test.sh 748
tests/fm-brief-test-scope.test.sh 897
tests/fm-brief.test.sh 10694
tests/fm-busy-adapter-wiring.test.sh 2128
tests/fm-busy-state.test.sh 1653
tests/fm-calm-claude-mod-live-e2e.test.sh 1047
tests/fm-calm-claude-mod-plugin.test.sh 876
tests/fm-calm-claude-mod.test.sh 1050
tests/fm-calm-pi-extension.test.sh 2906
tests/fm-calm-pi-queue-retention-live-e2e.test.sh 799
tests/fm-capacity-auto.test.sh 1552
tests/fm-capacity.test.sh 1250
tests/fm-captain-hold-backend-compat.test.sh 946
tests/fm-captain-hold-lifecycle.test.sh 3504
tests/fm-captain-hold-teardown.test.sh 2851
tests/fm-cd-pretool-check.test.sh 1098
tests/fm-check-unregister.test.sh 976
tests/fm-ci-workflow.test.sh 1226
tests/fm-classify-corr-token.test.sh 4456
tests/fm-classify-decision-key.test.sh 4006
tests/fm-claude-account-quota.test.sh 873
tests/fm-claude-stop-autoarm-live-e2e.test.sh 874
tests/fm-claude-stop-autoarm.test.sh 2500
tests/fm-claude-tool-exclude-live.test.sh 1050
tests/fm-claude-trust.test.sh 1272
tests/fm-cmux-claude-composer-live-e2e.test.sh 1648
tests/fm-codex-continuity-live-e2e.test.sh 722
tests/fm-codex-hook-layer-live-e2e.test.sh 872
tests/fm-codex-stop-park.test.sh 996
tests/fm-commandcode-harness.test.sh 5836
tests/fm-commandcode-signals-live-e2e.test.sh 4882
tests/fm-composer-codex-idle-live-e2e.test.sh 746
tests/fm-composer-ghost.test.sh 1098
tests/fm-composer-lib.test.sh 2124
tests/fm-composer-matrix-live-e2e.test.sh 973
tests/fm-contributions.test.sh 3402
tests/fm-control-hc.test.sh 847
tests/fm-control-herdr-smoke.test.sh 946
tests/fm-control-relaunch.test.sh 18610
tests/fm-control.test.sh 10447
tests/fm-cortex-harness.test.sh 5962
tests/fm-cortex-signals-live-e2e.test.sh 5160
tests/fm-crew-state.test.sh 6060
tests/fm-cursor-harness.test.sh 7612
tests/fm-cursor-primary-live-e2e.test.sh 976
tests/fm-cursor-primary.test.sh 1322
tests/fm-daemon.test.sh 2942
tests/fm-devin-harness.test.sh 5611
tests/fm-devin-signals-live-e2e.test.sh 4554
tests/fm-dispatch-resolve.test.sh 4908
tests/fm-documentation-audiences.test.sh 722
tests/fm-dod-lib.test.sh 9968
tests/fm-ensure-agents-md.test.sh 1074
tests/fm-extension-binding.test.sh 7618
tests/fm-fleet-ledger.test.sh 16474
tests/fm-fleet-snapshot-contribution-input.test.sh 696
tests/fm-fleet-snapshot-view.test.sh 3778
tests/fm-fleet-sync.test.sh 1352
tests/fm-forge-detect.test.sh 824
tests/fm-fork-free-helpers.test.sh 848
tests/fm-gate-refuse.test.sh 1402
tests/fm-gemini-harness.test.sh 946
tests/fm-git-push-guard.test.sh 772
tests/fm-git-strip-ai-trailers.test.sh 1046
tests/fm-gitignore-config.test.sh 124
tests/fm-gotmp.test.sh 170
tests/fm-grok-continuity-live-e2e.test.sh 900
tests/fm-grok-harness.test.sh 1051
tests/fm-grok-stop-live-e2e.test.sh 872
tests/fm-guard-stale-banner.test.sh 1526
tests/fm-harness-adapter-instructions-live-e2e.test.sh 1072
tests/fm-harness-adapter-references.test.sh 697
tests/fm-harness-liveness-drift-live-e2e.test.sh 976
tests/fm-harness-precedence.test.sh 1122
tests/fm-hc-lab.test.sh 798
tests/fm-herdr-attached-viewer-live-e2e.test.sh 847
tests/fm-herdr-groups.test.sh 996
tests/fm-herdr-lab.test.sh 1400
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh 846
tests/fm-herdr-projected-cd-live-e2e.test.sh 1077
tests/fm-herdr-session-cleanup-e2e.test.sh 150
tests/fm-herdr-session-cleanup.test.sh 1352
tests/fm-herdr-submit-confirm-live-e2e.test.sh 1476
tests/fm-herdr-version-floor-live-e2e.test.sh 926
tests/fm-hermes-gateway-coexistence-live-e2e.test.sh 871
tests/fm-hermes-harness.test.sh 5384
tests/fm-hermes-profile-safety-live-e2e.test.sh 748
tests/fm-hermes-signals-live-e2e.test.sh 5310
tests/fm-home-summary-refresh.test.sh 1698
tests/fm-host-mirror-live-e2e.test.sh 4258
tests/fm-host-mirror.test.sh 1100
tests/fm-inactive-reconcile.test.sh 2051
tests/fm-inbox.test.sh 1400
tests/fm-install-herdr.test.sh 696
tests/fm-jev-mem-guard.test.sh 70
tests/fm-kimi-delivery-live-e2e.test.sh 898
tests/fm-kimi-harness.test.sh 2103
tests/fm-kimi-trust-prompt-live-e2e.test.sh 896
tests/fm-kiro-harness.test.sh 1172
tests/fm-kiro-signals-live-e2e.test.sh 974
tests/fm-lane-capacity-integration.test.sh 1302
tests/fm-lane-vitals.test.sh 821
tests/fm-launch-mise-env.test.sh 122
tests/fm-launch-prompt-signals-live-e2e.test.sh 158
tests/fm-lavish-url.test.sh 1072
tests/fm-lint-feedback.test.sh 10346
tests/fm-lint-workflows.test.sh 972
tests/fm-lint.test.sh 2250
tests/fm-live-gate.test.sh 1099
tests/fm-live-lab-isolation.test.sh 1476
tests/fm-live-lab-up-mate.test.sh 896
tests/fm-live-lab.test.sh 1978
tests/fm-local-handoff.test.sh 1948
tests/fm-mail-check.test.sh 998
tests/fm-mail.test.sh 2328
tests/fm-merge-local.test.sh 16856
tests/fm-muse-harness.test.sh 4082
tests/fm-muse-signals-live-e2e.test.sh 4632
tests/fm-nm-respond.test.sh 124
tests/fm-nm-test-contract.test.sh 748
tests/fm-no-mistakes-required.test.sh 850
tests/fm-omp-harness.test.sh 6058
tests/fm-omp-primary-live-e2e.test.sh 1100
tests/fm-on.test.sh 2678
tests/fm-opencode-abs-cwd-rail-live-e2e.test.sh 824
tests/fm-opencode-primary-live-e2e.test.sh 1226
tests/fm-operational-input.test.sh 974
tests/fm-osc7501.test.sh 1624
tests/fm-pane-question-detector.test.sh 1124
tests/fm-parent-channel-scan-exclusion.test.sh 1076
tests/fm-park.test.sh 2528
tests/fm-peek-remote.test.sh 722
tests/fm-pending-reply.test.sh 1697
tests/fm-pi-branch-extension.test.sh 1674
tests/fm-pi-branch-live-e2e.test.sh 1000
tests/fm-pi-branch-responsiveness-live-e2e.test.sh 771
tests/fm-pi-codex-native.test.sh 774
tests/fm-pi-compaction-live-e2e.test.sh 1026
tests/fm-pi-primary-live-e2e.test.sh 972
tests/fm-pi-primary-types.test.sh 70
tests/fm-pi-seeded-home-trust-live-e2e.test.sh 926
tests/fm-pi-watch-extension.test.sh 2402
tests/fm-pi-windows-shell-invocation.test.sh 696
tests/fm-pi-worker-stream-live-e2e.test.sh 1498
tests/fm-pi-worktree-trust-live-e2e.test.sh 822
tests/fm-pipeline-spend.test.sh 1126
tests/fm-polytoken-harness.test.sh 1398
tests/fm-polytoken-signals-live-e2e.test.sh 4829
tests/fm-pr-check-security.test.sh 5180
tests/fm-pr-health.test.sh 1548
tests/fm-pr-merge.test.sh 5183
tests/fm-pr-review.test.sh 1424
tests/fm-pr-reviewers.test.sh 722
tests/fm-pr-state-live-e2e.test.sh 850
tests/fm-pr-state.test.sh 821
tests/fm-procevent-extension-errors.test.sh 72
tests/fm-procevent-quota.test.sh 270
tests/fm-procevent-retire-task.test.sh 10821
tests/fm-procevent-when.test.sh 3076
tests/fm-procevent.test.sh 14329
tests/fm-project-capacity.test.sh 1198
tests/fm-project-mode.test.sh 974
tests/fm-project-origin.test.sh 772
tests/fm-public-followup.test.sh 24282
tests/fm-quota-array-dispatch-live-e2e.test.sh 721
tests/fm-quota-choose.test.sh 320
tests/fm-read-repetition-live.test.sh 800
tests/fm-read-repetition.test.sh 721
tests/fm-record-export-remote-home.test.sh 746
tests/fm-record-export.test.sh 1576
tests/fm-remote-backlog-handoff.test.sh 1574
tests/fm-remote-delta-read.test.sh 1000
tests/fm-remote-doctor.test.sh 2228
tests/fm-remote-entrypoint.test.sh 722
tests/fm-remote-herdr-guard.test.sh 2526
tests/fm-remote-herdr-identity.test.sh 822
tests/fm-remote-inherit-generation.test.sh 8888
tests/fm-remote-job-claim-reap.test.sh 3753
tests/fm-remote-job-claim-retention.test.sh 2580
tests/fm-remote-job-launchagent.test.sh 2600
tests/fm-remote-job-orphan-reap.test.sh 924
tests/fm-remote-job-process-start.test.sh 2830
tests/fm-remote-job.test.sh 10039
tests/fm-remote-reply.test.sh 28186
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 4606
tests/fm-remote-secondmate-omp.test.sh 925
tests/fm-remote-secondmate-parent-binding.test.sh 897
tests/fm-remote-secondmate-relaunch.test.sh 2829
tests/fm-remote-secondmate-trace-context.test.sh 896
tests/fm-remote-transport-lanes.test.sh 3330
tests/fm-review-check.test.sh 900
tests/fm-review-diff.test.sh 1226
tests/fm-rovo-harness.test.sh 3377
tests/fm-rovo-signals-live-e2e.test.sh 1576
tests/fm-secondmate-busy-contract-live-e2e.test.sh 1826
tests/fm-secondmate-harness.test.sh 2876
tests/fm-secondmate-lifecycle-e2e.test.sh 1126
tests/fm-secondmate-liveness.test.sh 1298
tests/fm-secondmate-reconcile.test.sh 1727
tests/fm-secondmate-restart.test.sh 1298
tests/fm-secondmate-safety.test.sh 3504
tests/fm-secondmate-sleep.test.sh 1074
tests/fm-secondmate-sync.test.sh 2930
tests/fm-self-repo-role.test.sh 1652
tests/fm-send-agy-confirm.test.sh 875
tests/fm-send-inbox-doorbell-live-e2e.test.sh 924
tests/fm-send-inbox.test.sh 1702
tests/fm-send-kiro-confirm.test.sh 721
tests/fm-send-popup-settle.test.sh 772
tests/fm-send-remote-delivery.test.sh 23000
tests/fm-send-resolve-key.test.sh 2054
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 771
tests/fm-send-secondmate-marker.test.sh 1076
tests/fm-send-settle.test.sh 772
tests/fm-send-strict.test.sh 997
tests/fm-session-lock-ancestry.test.sh 1648
tests/fm-session-lock-ps-denied.test.sh 1172
tests/fm-session-lock-windows-consumers.test.sh 900
tests/fm-session-start.test.sh 4030
tests/fm-sessionstart-hook-live-e2e.test.sh 1150
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 976
tests/fm-sessionstart-nudge.test.sh 1200
tests/fm-shared-captain-inheritance.test.sh 1097
tests/fm-spawn-batch.test.sh 772
tests/fm-spawn-compact-adviser-disable-remote.test.sh 926
tests/fm-spawn-compact-adviser-disable.test.sh 1276
tests/fm-spawn-dispatch-profile.test.sh 3727
tests/fm-spawn-external-review.test.sh 896
tests/fm-spawn-herdr-lease.test.sh 1126
tests/fm-spawn-manual-pr-text.test.sh 846
tests/fm-spawn-orca-worktree.test.sh 1398
tests/fm-spawn-pool-base-freshen.test.sh 2353
tests/fm-spawn-worktree-settle.test.sh 1049
tests/fm-startup-growth-check.test.sh 2927
tests/fm-startup-memory-budget.test.sh 896
tests/fm-startup-network.test.sh 1574
tests/fm-stat-shadowing.test.sh 54
tests/fm-stow-cascade.test.sh 1075
tests/fm-stow-guard.test.sh 946
tests/fm-subagent-pretool-check.test.sh 846
tests/fm-supervision-events.test.sh 821
tests/fm-supervision-host-attended-live-e2e.test.sh 4760
tests/fm-supervision-host-drain.test.sh 2502
tests/fm-supervision-host-herdr-live-e2e.test.sh 1376
tests/fm-supervision-host-hook.test.sh 2249
tests/fm-supervision-host-live-e2e.test.sh 821
tests/fm-supervision-host-park.test.sh 2300
tests/fm-supervision-host.test.sh 3130
tests/fm-supervision-instructions.test.sh 1150
tests/fm-t3-mcp.test.sh 1498
tests/fm-tangle-guard.test.sh 1152
tests/fm-task-budget.test.sh 822
tests/fm-task-delivery.test.sh 2426
tests/fm-task-inbox.test.sh 2302
tests/fm-tasks-axi.test.sh 922
tests/fm-teardown-endpoint-safety.test.sh 2227
tests/fm-teardown-procevent.test.sh 10618
tests/fm-teardown.test.sh 5860
tests/fm-test-fixture-cleanup.test.sh 772
tests/fm-test-fixtures.test.sh 1072
tests/fm-test-isolation-proof.test.sh 796
tests/fm-test-linux.test.sh 824
tests/fm-test-remote.test.sh 199
tests/fm-test-run.test.sh 2730
tests/fm-test-tap-verify.test.sh 746
tests/fm-timeout-lib.test.sh 2977
tests/fm-tmux-agent-liveness.test.sh 3853
tests/fm-tmux-submit-busy.test.sh 947
tests/fm-tool-update-check.test.sh 2102
tests/fm-trace-context-lib.test.sh 820
tests/fm-trace-context-spawn.test.sh 1326
tests/fm-transition-lib.test.sh 849
tests/fm-treehouse-clone-custody.test.sh 1024
tests/fm-turnend-foreign-owner-arm-fix.test.sh 70
tests/fm-turnend-guard.test.sh 2575
tests/fm-update.test.sh 1072
tests/fm-usage-warner.test.sh 1277
tests/fm-vendor-auth-probe.test.sh 1052
tests/fm-voice-relay.test.sh 1752
tests/fm-wake-daemon-lifecycle-e2e.test.sh 1074
tests/fm-wake-drain-open-decisions-cursor.test.sh 1173
tests/fm-wake-drain-open-decisions.test.sh 972
tests/fm-wake-drain-outcome-backstop.test.sh 1197
tests/fm-wake-drain-unread-status.test.sh 1172
tests/fm-wake-queue.test.sh 4004
tests/fm-warm-compact-herdr-live-e2e.test.sh 946
tests/fm-warm-compact.test.sh 9268
tests/fm-watch-arm.test.sh 2400
tests/fm-watch-beacon.test.sh 871
tests/fm-watch-checkpoint.test.sh 1274
tests/fm-watch-inbox-meta.test.sh 826
tests/fm-watch-inbox-progress.test.sh 976
tests/fm-watch-open-decisions.test.sh 163
tests/fm-watch-recovery-loop.test.sh 1022
tests/fm-watch-triage-busy.test.sh 3002
tests/fm-watch-triage-pause.test.sh 3756
tests/fm-watch-triage-wedge-defer.test.sh 2404
tests/fm-watch-triage.test.sh 5410
tests/fm-watch-wedge-cap-live.test.sh 2178
tests/fm-watch-wedge-cap-unconfigured-parity.test.sh 996
tests/fm-watch-wedge-cap.test.sh 2626
tests/fm-watcher-lock.test.sh 2776
tests/fm-worker-account-live-e2e.test.sh 1222
tests/fm-worker-account.test.sh 1652
tests/fm-x-mode.test.sh 4407
tests/git-config-helpers.sh 69
tests/hc-fake-fixture.sh 70
tests/hc-test-safety.sh 70
tests/herdr-client-pair-fixture.sh 72
tests/herdr-test-safety.sh 74
tests/lib.sh 698
tests/remote-herdr-fixture.sh 69
tests/rex-fake-fixture.sh 72
tests/rex-test-safety.sh 172
tests/secondmate-helpers.sh 798
tests/secondmate-persist-helpers.sh 69
tests/supervision-host-helpers.sh 1827
tests/t3-fake-lib.sh 70
tests/tern-test-safety.sh 70
tests/wake-helpers.sh 746
tests/watch-triage-helpers.sh 1124
tests/zellij-test-safety.sh 74
EOF
}

# Resolve one canonical root's partition weight: the measured duration hint
# when present, else the unhinted default. Emits "<weight_ms>\t<index>\t<path>"
# for every root, the same stable shape fm_lint_root_weights produces.
fm_lint_root_partition_weights() {
  local index=1 path
  for path in "${ROOTS[@]}"; do
    case "$path" in
      *"$TAB"*|*$'\n'*)
        printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
        return 2
        ;;
    esac
    printf '%s\t%s\n' "$index" "$path"
    index=$((index + 1))
  done | awk -v default_ms="$FM_LINT_DEFAULT_ROOT_WEIGHT_MS" '
    NR == FNR { if (NF) { hint[$1] = $2 }; next }
    {
      w = ($2 in hint) ? hint[$2] : default_ms
      printf "%s\t%s\t%s\n", w, $1, $2
    }
  ' <(fm_lint_root_duration_hints) -
}

# Stable largest-first packing is shared by cross-runner partition selection
# and the two local workers. Weights are a scheduling proxy, never a skip rule.
TAB=$(printf '\t')
fm_lint_root_weights() {
  local index=1 path weight
  for path in "${ROOTS[@]}"; do
    case "$path" in
      *"$TAB"*|*$'\n'*)
        printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
        return 2
        ;;
    esac
    if [ -n "${FM_LINT_CACHE_HIT[index]:-}" ]; then
      index=$((index + 1))
      continue
    fi
    weight=1
    if [ -f "$path" ]; then
      weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
    printf '%s\t%s\t%s\n' "$weight" "$index" "$path"
    index=$((index + 1))
  done
}

if [ -n "$PARTITION" ] && [ "${#ROOTS[@]}" -gt 0 ]; then
  PARTITION_ROOTS=()
  partition_weights=$(fm_lint_root_partition_weights) || exit $?
  while IFS="$TAB" read -r index path; do
    PARTITION_ROOTS+=("$path")
  done < <(printf '%s\n' "$partition_weights" | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n | awk -F '\t' -v want="${PARTITION%%of*}" -v bins="$FM_LINT_CI_PARTITIONS" '
    {
      shard=1
      for (candidate=2; candidate<=bins; candidate++) {
        if (load[candidate] < load[shard]) shard=candidate
      }
      load[shard]+=$1
      if (shard == want) print $2 "\t" $3
    }
  ' | LC_ALL=C sort -t "$TAB" -k1,1n)
  if [ "${#PARTITION_ROOTS[@]}" -gt 0 ]; then
    ROOTS=("${PARTITION_ROOTS[@]}")
  else
    ROOTS=()
  fi
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

if ! SHELLCHECK_BIN=$(type -P shellcheck); then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
if ! PERL_BIN=$(type -P perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$(env -u SHELLCHECK_OPTS "$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
elif [ "$FOLLOW_SOURCES" -eq 0 ]; then
  printf 'fm-lint.sh: local changed-file mode; ShellCheck source following disabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ "$ROOT_COUNT" -eq 0 ]; then
  if [ -n "$PARTITION" ]; then
    printf 'fm-lint.sh: no lint targets in this partition\n'
  elif [ "$CHANGED_MODE" -eq 1 ]; then
    printf 'fm-lint.sh: no changed lint targets\n'
  else
    printf 'fm-lint.sh: no lint targets\n'
  fi
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

# Per-root bounded-execution envelope. Under FM_LINT_REQUIRE_BOUNDS=1 the
# watchdog is probed and the host's acceptance of ulimit -v is checked before
# any root starts; failed checks refuse with a named error. A required-bounds run
# never lints uncapped. Without it a local run applies the envelope when the
# host can and otherwise refuses, unless FM_LINT_ALLOW_UNBOUNDED_LOCAL=1 lets a
# smaller selection run each root unbounded after a warning.
ROOT_SECONDS=${FM_LINT_ROOT_SECONDS:-1200}
ROOT_GRACE=${FM_LINT_ROOT_GRACE:-5}
# 12 GiB of virtual address space per analysis process. ulimit -v caps
# address space, not resident memory; ShellCheck's GHC runtime reserves about
# a third of that space, leaving ~8 GiB usable heap per root. Measured x86_64
# demand for the heaviest roots is near 5.5-6 GiB: the 8 GiB address-space
# cap's ~5.33 GiB wall caught bin/fm-spawn.sh, bin/fm-teardown.sh,
# tests/fm-pending-reply.test.sh, and
# tests/fm-launch-prompt-signals-live-e2e.test.sh. CI runs one root per
# lint job, so worst-case resident demand is ~8 GiB plus runner overhead,
# inside the 16 GiB runner. Local runs fit workers x cap into
# FM_LINT_LOCAL_MEMORY_BUDGET_GIB, so the 12 GiB cap means one local worker
# under the 16 GiB default. A root that exceeds its cap fails by name.
# Never disable, narrow, or redirect source-following to fit a root under
# the cap; the known-heavy list only skips an attempt the memory retry already
# replaces on every run. The roots sidecar records each root's peak RSS; roots peaking
# above about 3 GiB resident are reduction candidates,
# bin/fm-pending-reply-lib.sh first (its separate dedup fix is PR 5753).
ROOT_MEMORY_KIB=${FM_LINT_ROOT_MEMORY_KIB:-$FM_LINT_DEFAULT_ROOT_MEMORY_KIB}
for bound_pair in \
  "FM_LINT_ROOT_SECONDS=$ROOT_SECONDS" \
  "FM_LINT_ROOT_GRACE=$ROOT_GRACE" \
  "FM_LINT_ROOT_MEMORY_KIB=$ROOT_MEMORY_KIB"; do
  case "${bound_pair#*=}" in
    ''|0*|*[!0-9]*|?????????????*)
      printf 'fm-lint.sh: %s must be a positive integer below 1000000000000, got %s.\n' \
        "${bound_pair%%=*}" "${bound_pair#*=}" >&2
      exit 2
      ;;
  esac
done

# A local run holds JOBS x ROOT_MEMORY_KIB within a total budget
# (FM_LINT_LOCAL_MEMORY_BUDGET_GIB, default 16 GiB): the default worker count
# drops to fit, and an explicit count or a per-root cap above it refuses.
if [ "$ROOT_COUNT" -gt 0 ] && [ "$LOCAL_RUN" -eq 1 ]; then
  LOCAL_BUDGET_GIB=${FM_LINT_LOCAL_MEMORY_BUDGET_GIB:-16}
  case "$LOCAL_BUDGET_GIB" in
    ''|0*|*[!0-9]*|????????*)
      printf 'fm-lint.sh: FM_LINT_LOCAL_MEMORY_BUDGET_GIB must be a positive integer below 10000000, got %s.\n' \
        "$LOCAL_BUDGET_GIB" >&2
      exit 2
      ;;
  esac
  local_jobs_max=$((LOCAL_BUDGET_GIB * 1048576 / ROOT_MEMORY_KIB))
  if [ "$local_jobs_max" -lt 1 ]; then
    printf 'fm-lint.sh: per-root cap FM_LINT_ROOT_MEMORY_KIB=%s exceeds the local memory budget FM_LINT_LOCAL_MEMORY_BUDGET_GIB=%s.\n' \
      "$ROOT_MEMORY_KIB" "$LOCAL_BUDGET_GIB" >&2
    exit 2
  fi
  if [ "$JOBS" -gt "$local_jobs_max" ]; then
    if [ "$JOBS_EXPLICIT" -eq 1 ]; then
      printf 'fm-lint.sh: %s local workers x FM_LINT_ROOT_MEMORY_KIB=%s exceeds the local memory budget FM_LINT_LOCAL_MEMORY_BUDGET_GIB=%s; use --jobs %s or raise the budget.\n' \
        "$JOBS" "$ROOT_MEMORY_KIB" "$LOCAL_BUDGET_GIB" "$local_jobs_max" >&2
      exit 2
    fi
    JOBS=$local_jobs_max
  fi
fi

BOUND_MECH=none
if [ "$ROOT_COUNT" -gt 0 ] && [ "${FM_LINT_REQUIRE_BOUNDS:-0}" = 1 ]; then
  bounds_problems=()
  if declare -F fm_exec_timed >/dev/null 2>&1; then
    # perl is mandatory above, so fm_exec_timed always takes its perl watchdog.
    BOUND_MECH=perl
  else
    bounds_problems+=('bin/fm-timeout-lib.sh is missing beside fm-lint.sh, so no watchdog is available')
  fi
  if [ "$BOUND_MECH" != none ]; then
    # Exercise the real bound end to end before any root starts: a clean probe
    # must exit 0 and an over-deadline probe must come back as a timeout, so a
    # watchdog that cannot actually bound a command (a perl without
    # Time::HiRes, say) refuses the run here instead of failing every root at
    # run time.
    probe_rc=0
    ( fm_exec_timed 30 1 true ) >/dev/null 2>&1 || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
      bounds_problems+=("the timeout watchdog could not run a probe command (rc=$probe_rc)")
    else
      probe_rc=0
      ( fm_exec_timed 2 1 sleep 30 ) >/dev/null 2>&1 || probe_rc=$?
      case "$probe_rc" in
        124|137) : ;;
        *) bounds_problems+=("the timeout watchdog did not bound an over-deadline probe (rc=$probe_rc)") ;;
      esac
    fi
  fi
  ( ulimit -v "$ROOT_MEMORY_KIB" ) 2>/dev/null \
    || bounds_problems+=("per-root memory limit FM_LINT_ROOT_MEMORY_KIB=$ROOT_MEMORY_KIB KiB is not enforceable on this host (ulimit -v)")
  if [ "${#bounds_problems[@]}" -gt 0 ]; then
    for problem in "${bounds_problems[@]}"; do
      printf 'fm-lint.sh: bounds required but %s.\n' "$problem" >&2
    done
    printf 'fm-lint.sh: refusing to lint uncapped under FM_LINT_REQUIRE_BOUNDS=1.\n' >&2
    exit 2
  fi
elif [ "$ROOT_COUNT" -gt 0 ] && [ "$LOCAL_RUN" -eq 1 ]; then
  # Bound every root when the host can. Otherwise the full set always refuses,
  # and any other local run refuses before ShellCheck unless
  # FM_LINT_ALLOW_UNBOUNDED_LOCAL=1 accepts an unbounded run.
  if declare -F fm_exec_timed >/dev/null 2>&1 \
    && ( fm_exec_timed 30 1 true ) >/dev/null 2>&1 \
    && ( ulimit -v "$ROOT_MEMORY_KIB" ) 2>/dev/null; then
    BOUND_MECH=perl
  elif [ "$CANONICAL_SET" -eq 1 ]; then
    printf 'fm-lint.sh: this host cannot enforce the per-root bounds (ulimit -v or the timeout watchdog); refusing the full canonical lint uncapped. Run it in a capped sandbox (for example a Boat sandbox started with --no-env) or in CI.\n' >&2
    exit 2
  elif [ "${FM_LINT_ALLOW_UNBOUNDED_LOCAL:-0}" = 1 ]; then
    printf 'fm-lint.sh: warning: this host cannot enforce the per-root bounds (ulimit -v or the timeout watchdog); linting unbounded because FM_LINT_ALLOW_UNBOUNDED_LOCAL=1.\n' >&2
  else
    printf 'fm-lint.sh: this host cannot enforce the per-root bounds (ulimit -v or the timeout watchdog); refusing to lint uncapped. Run it in a capped sandbox (for example a Boat sandbox started with --no-env) or in CI, or set FM_LINT_ALLOW_UNBOUNDED_LOCAL=1 to accept an unbounded local run.\n' >&2
    exit 2
  fi
fi

WORKER_NICE=()
if [ "$LOCAL_RUN" -eq 1 ] && NICE_BIN=$(type -P nice); then
  WORKER_NICE=("$NICE_BIN" -n 10)
fi

PROGRESS=0
if [ -n "$PARTITION" ]; then
  PROGRESS=1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"

# The roots log is the retained per-root lifecycle sidecar; beside --telemetry
# it survives as ${TELEMETRY%.tsv}.roots.tsv even when a run is killed
# mid-flight.
if [ -n "$TELEMETRY" ]; then
  ROOTS_LOG=${TELEMETRY%.tsv}.roots.tsv
else
  ROOTS_LOG=$TMP_ROOT/roots.tsv
fi
: > "$ROOTS_LOG"
if [ "$BOUND_MECH" != none ]; then
  bounds_applied=1
  root_deadline_meta=$ROOT_SECONDS
  root_grace_meta=$ROOT_GRACE
  root_memory_meta=$ROOT_MEMORY_KIB
else
  bounds_applied=0
  root_deadline_meta=unbounded
  root_grace_meta=unbounded
  root_memory_meta=unbounded
fi
{
  printf 'format\t%s\n' 'fm-lint-roots-v1'
  printf 'meta\t%s\t%s\n' 'shellcheck_version' "$resolved"
  printf 'meta\t%s\t%s\n' 'platform' "$(uname -s) $(uname -m)"
  printf 'meta\t%s\t%s\n' 'image_os' "${ImageOS:-unknown}"
  printf 'meta\t%s\t%s\n' 'image_version' "${ImageVersion:-unknown}"
  printf 'meta\t%s\t%s\n' 'mode' "$ANALYSIS_MODE"
  printf 'meta\t%s\t%s\n' 'partition' "${PARTITION:-all}"
  printf 'meta\t%s\t%s\n' 'jobs' "$JOBS"
  printf 'meta\t%s\t%s\n' 'bounds_enforced' "$bounds_applied"
  printf 'meta\t%s\t%s\n' 'root_deadline_seconds' "$root_deadline_meta"
  printf 'meta\t%s\t%s\n' 'root_kill_grace_seconds' "$root_grace_meta"
  printf 'meta\t%s\t%s\n' 'root_memory_limit_kib' "$root_memory_meta"
  printf 'meta\t%s\t%s\n' 'timing_mechanism' "$BOUND_MECH"
} >> "$ROOTS_LOG"

# The per-root pass cache (bin/fm-lint-cache-lib.sh): with FM_LINT_CACHE_DIR
# set, roots whose exact key holds a recorded pass are skipped; the audit flags
# lint every selected root without reading or writing it.
LINT_COUNT=$ROOT_COUNT
FM_LINT_CACHE_STATE=off
if [ -n "${FM_LINT_CACHE_DIR:-}" ] || [ "$NO_CACHE" -eq 1 ]; then
  if declare -F fm_lint_cache_begin >/dev/null 2>&1; then
    fm_lint_cache_begin
  elif [ "$NO_CACHE" -eq 0 ]; then
    printf 'fm-lint.sh: lint cache unavailable (bin/fm-lint-cache-lib.sh is missing); linting every root\n' >&2
    FM_LINT_CACHE_STATE=disabled
  fi
fi

SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

WORKER_LOADS=(0 0)
if [ "$LINT_COUNT" -gt 0 ]; then
  fm_lint_root_weights > "$WEIGHTS" || exit $?

  # Largest-first deterministic greedy assignment balances the two worker
  # queues without affecting replay order. Direct bytes are a stable portable
  # proxy after the expensive dynamic adapter source fan-out is cut.
  LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
  while IFS="$TAB" read -r weight index path; do
    worker=0
    if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
      worker=1
    fi
    printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
    WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
  done < "$WEIGHTS.sorted"
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
    mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
    worker=$((worker + 1))
  done
else
  : > "$WEIGHTS"
fi

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  local -a worker_env
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  worker_env=(
    FM_LINT_INTERNAL=1
    FM_LINT_INTERNAL_FAST="$FAST"
    FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES"
    FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES"
    FM_LINT_INTERNAL_BOUNDED="$BOUND_MECH"
    FM_LINT_INTERNAL_MEMORY_KIB="$ROOT_MEMORY_KIB"
    FM_LINT_INTERNAL_ROOT_SECS="$ROOT_SECONDS"
    FM_LINT_INTERNAL_GRACE="$ROOT_GRACE"
    FM_LINT_INTERNAL_ROOTS_LOG="$ROOTS_LOG"
    FM_LINT_INTERNAL_MODE="$ANALYSIS_MODE"
    FM_LINT_INTERNAL_PROGRESS="$PROGRESS"
    FM_LINT_SHELLCHECK="$SHELLCHECK_BIN"
    FM_LINT_PERL_BIN="$PERL_BIN"
  )
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        ${WORKER_NICE[@]+"${WORKER_NICE[@]}"} /usr/bin/time -lp -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        ${WORKER_NICE[@]+"${WORKER_NICE[@]}"} /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      ${WORKER_NICE[@]+"${WORKER_NICE[@]}"} env "${worker_env[@]}" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

overall_rc=0
if [ "$LINT_COUNT" -gt 0 ]; then
  if [ "$JOBS" -eq 1 ]; then
    worker=0
    while [ "$worker" -lt "$SHARD_COUNT" ]; do
      fm_lint_start_worker "$worker"
      fm_lint_wait_workers
      worker=$((worker + 1))
    done
  else
    worker=0
    while [ "$worker" -lt "$SHARD_COUNT" ]; do
      fm_lint_start_worker "$worker"
      worker=$((worker + 1))
    done
    fm_lint_wait_workers
  fi

  # Replay both stable shards in deterministic order and select the first nonzero
  # shard status. ShellCheck processes every root in a shard after earlier findings.
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    output="$OUTPUT_DIR/shard.$worker"
    [ ! -f "$output.out" ] || cat "$output.out"
    if [ -f "$output.rc" ]; then
      rc=$(cat "$output.rc" 2>/dev/null || printf '2')
      case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
    else
      printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
      rc=2
    fi
    if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
      overall_rc=$rc
    fi
    worker=$((worker + 1))
  done
fi

# Close the roots log with completion counts so a mid-run kill leaves
# begun-but-unfinished roots attributable by name. result_exit is appended
# after the purity and workflow checks so it records the run's final status.
if [ -s "$ROOTS_LOG" ]; then
  read -r roots_completed roots_unfinished roots_begun <<EOF
$(awk -F '\t' '
  $1 == "begin" { begun[$2 FS $3] = 1; total++ }
  $1 == "end" { ended[$2 FS $3] = 1; done_count++ }
  END { unfinished = 0; for (key in begun) if (!(key in ended)) unfinished++
        printf "%d %d %d\n", done_count + 0, unfinished, total + 0 }
' "$ROOTS_LOG")
EOF
  {
    printf 'meta\t%s\t%s\n' 'roots_begun' "$roots_begun"
    printf 'meta\t%s\t%s\n' 'roots_completed' "$roots_completed"
    printf 'meta\t%s\t%s\n' 'roots_unfinished' "$roots_unfinished"
  } >> "$ROOTS_LOG"
fi

if declare -F fm_lint_cache_report >/dev/null 2>&1; then
  fm_lint_cache_finish
  fm_lint_cache_audit
  if [ -n "$TELEMETRY" ]; then
    fm_lint_cache_report "${TELEMETRY%.tsv}.cache.tsv"
  else
    fm_lint_cache_report ''
  fi
  if [ "${FM_LINT_CACHE_STALE:-0}" -gt 0 ]; then
    overall_rc=3
  fi
else
  # The library's reporter is absent: print its summary shape from here.
  FM_LINT_CACHE_HITS=0 FM_LINT_CACHE_MISSES=$ROOT_COUNT FM_LINT_CACHE_STORED=0
  printf 'fm-lint.sh: lint cache: hits=0 misses=%s stored=0 uncacheable=0 scope=%s state=%s\n' \
    "$ROOT_COUNT" "$([ "$LOCAL_RUN" -eq 1 ] && printf local || printf hosted)" "$FM_LINT_CACHE_STATE" >&2
fi

purity_rc=0
fm_lint_run_backend_purity || purity_rc=$?
if [ "$overall_rc" -eq 0 ] && [ "$purity_rc" -ne 0 ]; then
  overall_rc=$purity_rc
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=0
  if [ "$ROOT_COUNT" -gt 0 ]; then
    direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  fi
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  source_followed=0
  awk -F '\t' '$1 == "end" && $12 == 0 { print $2 }' "$ROOTS_LOG" > "$TMP_ROOT/no-source-indices"
  root_index=0
  if [ "$ROOT_COUNT" -gt 0 ]; then
    for path in "${ROOTS[@]}"; do
      root_index=$((root_index + 1))
      if [ -f "$path" ]; then
        bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
        case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
        direct_bytes=$((direct_bytes + bytes))
        cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
        awk '
          /^[[:space:]]*# shellcheck source=/ {
            target=$0
            sub(/^[[:space:]]*# shellcheck source=/, "", target)
            sub(/[[:space:]].*$/, "", target)
            print target
          }
        ' "$path" > "$TMP_ROOT/root-source-targets"
        cat "$TMP_ROOT/root-source-targets" >> "$TMP_ROOT/source-targets"
        if [ "$FOLLOW_SOURCES" -eq 1 ] \
          && ! grep -qx "$root_index" "$TMP_ROOT/no-source-indices"; then
          followed_here=$(grep -cv '^/dev/null$' "$TMP_ROOT/root-source-targets" || true)
          source_followed=$((source_followed + followed_here))
        fi
      fi
    done
  fi
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'partition\t%s\n' "${PARTITION:-all}"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_bounds_enforced\t%s\n' "$bounds_applied"
    printf 'root_deadline_seconds\t%s\n' "$root_deadline_meta"
    printf 'root_kill_grace_seconds\t%s\n' "$root_grace_meta"
    printf 'root_memory_limit_kib\t%s\n' "$root_memory_meta"
    printf 'root_timing_mechanism\t%s\n' "$BOUND_MECH"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${WORKER_LOADS[0]}"
    printf 'shard_2_weight_bytes\t%s\n' "${WORKER_LOADS[1]:-0}"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'cache_state\t%s\n' "$FM_LINT_CACHE_STATE"
    printf 'cache_hits\t%s\n' "${FM_LINT_CACHE_HITS:-0}"
    printf 'cache_misses\t%s\n' "${FM_LINT_CACHE_MISSES:-$ROOT_COUNT}"
    printf 'cache_stored\t%s\n' "${FM_LINT_CACHE_STORED:-0}"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

if [ -s "$ROOTS_LOG" ]; then
  printf 'meta\t%s\t%s\n' 'result_exit' "$overall_rc" >> "$ROOTS_LOG"
fi

exit "$overall_rc"
