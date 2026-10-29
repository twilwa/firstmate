#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI selects
# canonical partitions; no-mistakes invokes the context-selected default, so
# both use this owner without duplicating lint configuration.
# The explicit --fast mode is local-only and disables ShellCheck's extended
# dataflow analysis while preserving ordinary shell lint checks and source
# following. CI, main, and merge-base-less runs attempt --norc
# --external-sources with full dataflow for each canonical root. An ordinary
# local branch (changed-file mode, including the no-mistakes lint step) drops
# --external-sources, keeps dataflow, and excludes SC1091, SC2034, SC2153,
# and SC2329, the codes that need library context. CI checks those codes
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
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh, with
#     --external-sources and full dataflow first. CI coverage never depends
#     on a local diff; memory failures may take the narrower retry below.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). That local pass drops --external-sources and excludes SC1091,
#     SC2034, SC2153, and SC2329. A branch with zero matching changed files
#     skips ShellCheck and prints a "no changed lint targets" note, then
#     still runs the backend-purity check and validates workflows.
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
# memory-limited runner. Diagnostics replay in stable shard/root order.
# FM_LINT_JOBS/--jobs change concurrency, not diagnostics or exit selection.
# --partition <k>of<N> splits the entire canonical inventory across N CI
# runners, where N is the owned partition count below. Partitions are
# complete, disjoint, and packed by measured per-root duration hints (byte
# weight stays only the two local workers' proxy; an unhinted root packs on
# FM_LINT_DEFAULT_ROOT_WEIGHT_MS); --list-files exposes their actual roots.
# Partition mode starts with full source-aware analysis, never changed-only
# or --fast, and does not accept explicit paths. Each partition also runs
# workflow lint and backend-purity checks, keeping either invocation
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
# named error, so a required-bounds run never lints uncapped. Without
# FM_LINT_REQUIRE_BOUNDS (a local developer lint, where hosts like macOS
# cannot apply the address-space limit at all) each root still runs in its
# own ShellCheck process with identical diagnostics, just unbounded.
#
# If a source-following root exits with a memory failure, it is retried once
# without --external-sources under the same memory limit and only the time
# left in that root's original deadline; with under a second left, the
# memory failure stands without a retry. A clean retry passes
# with an explicit memory-fallback reason and warning; only the same
# cross-file-dependent codes omitted in local no-source lint are excluded.
# Other findings and failed retries still fail lint. The retry's diagnostics
# replace the failed attempt's output; peak RSS is the maximum of both attempts.
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
# timeout, memory, signal:<sig>, limit-unavailable, or error:<rc>.
# Memory requires process-level evidence (a GHC exhaustion status or runtime
# error on stderr), not an echoed source excerpt or an OOM phrase in a
# filename. In partition mode begin/end
# lines also stream to stderr, and an abnormal root end is always reported
# there.
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
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u

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
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

# The sibling timeout library supplies the shared group-kill watchdog that
# bounds each root when FM_LINT_REQUIRE_BOUNDS=1 requires it; without the
# library a required-bounds run refuses in preflight rather than lint uncapped.
if [ -r "$SELF_DIR/fm-timeout-lib.sh" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SELF_DIR/fm-timeout-lib.sh"
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
    "$FM_LINT_SHELLCHECK" "$@" -- "$path" > "$root_out" 2> "$root_err" &
    FM_LINT_WORKER_RUN_PID=$!
    wait "$FM_LINT_WORKER_RUN_PID" || invocation_rc=$?
    FM_LINT_WORKER_RUN_PID=
  fi
  FM_LINT_LAST_RC=$invocation_rc
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
  local start_ms end_ms duration_ms invocation_rc=0 reason rss_kib initial_rc initial_reason
  local fallback_secs
  local final_follow_sources=${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}
  local -a fallback_args
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
    fallback_args=()
    for arg in "${FM_LINT_WORKER_ARGS[@]}"; do
      [ "$arg" = --external-sources ] || fallback_args+=("$arg")
    done
    [ -z "$LOCAL_NOX_EXCLUDE" ] || fallback_args+=("--exclude=$LOCAL_NOX_EXCLUDE")
    fm_lint_exec_root "$path" "$fallback_out" "$fallback_err" "$fallback_rss" \
      "$fallback_secs" "${fallback_args[@]}"
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
  end_ms=$(fm_lint_now_ms)
  duration_ms=$((end_ms - start_ms))
  if [ -n "${FM_LINT_INTERNAL_ROOTS_LOG:-}" ]; then
    printf 'end\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$index" "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-}" \
      "$start_ms" "$end_ms" "$duration_ms" "$invocation_rc" "$reason" "$rss_kib" "$final_follow_sources" \
      >> "$FM_LINT_INTERNAL_ROOTS_LOG"
  fi
  if [ "${FM_LINT_INTERNAL_PROGRESS:-0}" = 1 ] || { [ "$reason" != ok ] && [ "$reason" != findings ] && [ "$reason" != memory-fallback ]; }; then
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
LIST_FILES=0
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
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
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

if [ -z "$JOBS" ]; then
  if [ -n "$PARTITION" ]; then JOBS=1; else JOBS=2; fi
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
      printf 'fm-lint.sh: --partition requires full canonical lint; omit --fast and explicit paths.\n' >&2
      exit 2
    fi
    ;;
  *) fm_lint_partition_refuse "$PARTITION" ;;
esac

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
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
EXPLICIT_PATHS=0
FOLLOW_SOURCES=1
EXCLUDE_CODES=
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ -z "$PARTITION" ] && [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
if [ "$CHANGED_MODE" -eq 1 ] && [ "$FAST" -eq 0 ]; then
  FOLLOW_SOURCES=0
  EXCLUDE_CODES=$LOCAL_NOX_EXCLUDE
  ANALYSIS_MODE=local
fi
# Measured per-root source-aware lint durations in milliseconds ("<path> <ms>"
# per line): the slowest completed sample (rc 0, reason ok or memory-fallback)
# in the *.roots.tsv sidecars of hosted CI runs 40664798225, 40673507764,
# 40703025845, and 40796972623 (docs/fm-test-portable-shards.md "Lint
# partitions and end-to-end latency"). They weight only the cross-runner partition
# packing; coverage never depends on them. A canonical root missing here packs
# on FM_LINT_DEFAULT_ROOT_WEIGHT_MS.
fm_lint_root_duration_hints() {
  cat <<'EOF'
bin/backends/cmux.sh 1928
bin/backends/herdr.sh 15467
bin/backends/orca.sh 1728
bin/backends/paseo.sh 12160
bin/backends/rex.sh 13257
bin/backends/t3code.sh 2233
bin/backends/tern.sh 4040
bin/backends/tmux.sh 5142
bin/backends/zellij.sh 2385
bin/fm-afk-contract.sh 3838
bin/fm-afk-launch.sh 16921
bin/fm-afk-return.sh 23488
bin/fm-afk-start.sh 8397
bin/fm-agent-process-lib.sh 931
bin/fm-agy-trust.sh 180
bin/fm-approval-failover.sh 13063
bin/fm-arm-pretool-check.sh 183
bin/fm-backend-hometag-lib.sh 79
bin/fm-backend.sh 980
bin/fm-backlog-handoff.sh 49985
bin/fm-backlog-receive.sh 8598
bin/fm-backlog-transition-lib.sh 3436
bin/fm-bearings-board.sh 279
bin/fm-bearings-snapshot.sh 681
bin/fm-bootstrap.sh 36614
bin/fm-branch-outcome.sh 13263
bin/fm-branch-prompt.sh 80
bin/fm-branch-report.sh 13162
bin/fm-brief-heading-lib.sh 79
bin/fm-brief.sh 15618
bin/fm-busy-event.sh 880
bin/fm-busy-lib.sh 680
bin/fm-calendar-lib.sh 79
bin/fm-capacity.sh 1131
bin/fm-captain-hold.sh 23693
bin/fm-cd-pretool-check.sh 129
bin/fm-check-lib.sh 128
bin/fm-check-register.sh 1928
bin/fm-check-unregister.sh 2235
bin/fm-classify-lib.sh 6395
bin/fm-claude-stop-autoarm.sh 10102
bin/fm-claude-trust.sh 430
bin/fm-composer-lib.sh 1733
bin/fm-config-inherit-lib.sh 2081
bin/fm-config-push.sh 13614
bin/fm-contributions.sh 12658
bin/fm-control-lib.sh 279
bin/fm-control.sh 21428
bin/fm-cortex-plugin.sh 128
bin/fm-crew-state.sh 23534
bin/fm-cursor-lib.sh 379
bin/fm-decision-hold.sh 279
bin/fm-devin-config.sh 73
bin/fm-dispatch-resolve.sh 10353
bin/fm-doc-audience-check.sh 78
bin/fm-dod-lib.sh 8851
bin/fm-ensure-agents-md.sh 178
bin/fm-env-lib.sh 80
bin/fm-exclude-tools-lib.sh 126
bin/fm-extension.sh 73
bin/fm-external-review-lib.sh 2335
bin/fm-ff-lib.sh 881
bin/fm-fleet-ledger.sh 12158
bin/fm-fleet-snapshot.sh 15369
bin/fm-fleet-sync.sh 530
bin/fm-fleet-view.sh 78
bin/fm-forge-detect.sh 77
bin/fm-gate-refuse-lib.sh 126
bin/fm-gemini-lib.sh 128
bin/fm-git-push-guard.sh 2682
bin/fm-git-strip-ai-trailers.sh 174
bin/fm-guard.sh 7590
bin/fm-harness.sh 931
bin/fm-herdr-ci-cleanup.sh 129
bin/fm-herdr-groups.sh 14916
bin/fm-herdr-lab.sh 529
bin/fm-herdr-session-cleanup.sh 12960
bin/fm-hold-reason-lib.sh 78
bin/fm-home-seed.sh 11255
bin/fm-home-summary-refresh.sh 8647
bin/fm-hook-host-lib.sh 79
bin/fm-host-mirror.sh 8092
bin/fm-inactive-reconcile.sh 27046
bin/fm-inbox.sh 10701
bin/fm-install-actionlint.sh 128
bin/fm-install-herdr.sh 129
bin/fm-install-shellcheck.sh 130
bin/fm-install-treehouse.sh 129
bin/fm-jev-mem-guard.sh 78
bin/fm-kimi-delivery-lib.sh 78
bin/fm-kimi-trust-lib.sh 79
bin/fm-kimi-turnend-hook.sh 78
bin/fm-lab-home.sh 279
bin/fm-landed-lib.sh 78
bin/fm-launch-mise-env-lib.sh 78
bin/fm-lease-lib.sh 579
bin/fm-lease.sh 9100
bin/fm-line-cap-lib.sh 74
bin/fm-lint-workflows.sh 123
bin/fm-lint.sh 1331
bin/fm-live-lab.sh 880
bin/fm-local-handoff-lib.sh 1181
bin/fm-local-handoff.sh 14965
bin/fm-lock-lib.sh 124
bin/fm-lock.sh 10608
bin/fm-mail-check.sh 2836
bin/fm-mail.sh 19421
bin/fm-marker-lib.sh 430
bin/fm-merge-authority-lib.sh 6541
bin/fm-merge-local.sh 19081
bin/fm-merge-outcome-lib.sh 14713
bin/fm-nm-respond.sh 128
bin/fm-nm-run-lib.sh 379
bin/fm-omp-profile-lib.sh 78
bin/fm-on.sh 428
bin/fm-operational-input.sh 324
bin/fm-pane-question-lib.sh 4989
bin/fm-parent-channel-lib.sh 3187
bin/fm-path-lib.sh 77
bin/fm-peek.sh 1182
bin/fm-pending-reply-lib.sh 24690
bin/fm-pipeline-spend.sh 2279
bin/fm-polytoken-lib.sh 375
bin/fm-pr-check.sh 25698
bin/fm-pr-health.sh 12209
bin/fm-pr-lib.sh 1627
bin/fm-pr-merge.sh 40863
bin/fm-pr-poll.sh 179
bin/fm-pr-review-snapshot.sh 2234
bin/fm-pr-review.sh 3028
bin/fm-pr-reviewers.sh 2134
bin/fm-pr-risk.sh 128
bin/fm-pr-state.sh 2233
bin/fm-primary-scope-lib.sh 77
bin/fm-procevent-lavish.sh 13510
bin/fm-procevent-lib.sh 1381
bin/fm-procevent-quota.sh 10998
bin/fm-procevent-remote-reply.sh 40388
bin/fm-procevent-when.sh 13663
bin/fm-procevent.sh 18075
bin/fm-project-capacity-lib.sh 178
bin/fm-project-mode.sh 129
bin/fm-project-origin-lib.sh 128
bin/fm-promote.sh 47401
bin/fm-public-followup-collect.sh 16723
bin/fm-public-followup-emit.sh 17523
bin/fm-public-followup-lib.sh 13104
bin/fm-public-followup.sh 19780
bin/fm-push-transition-lib.sh 13413
bin/fm-quota-axi-lib.sh 126
bin/fm-quota-choose.sh 479
bin/fm-record-export.sh 8649
bin/fm-remote-delta-read.sh 281
bin/fm-remote-doctor.sh 3982
bin/fm-remote-entrypoint.sh 2132
bin/fm-remote-file.sh 8701
bin/fm-remote-herdr-guard.sh 279
bin/fm-remote-herdr-owner-lib.sh 179
bin/fm-remote-home-provision.sh 8748
bin/fm-remote-home-seed.sh 9049
bin/fm-remote-inherit-push.sh 2733
bin/fm-remote-inherit.sh 10854
bin/fm-remote-job-lib.sh 1732
bin/fm-remote-job-reap-orphans.sh 1981
bin/fm-remote-job-worker.sh 3487
bin/fm-remote-readiness-lib.sh 78
bin/fm-remote-secondmate-control.sh 29200
bin/fm-remote-secondmate-relaunch.sh 9649
bin/fm-review-check.sh 23539
bin/fm-review-diff.sh 230
bin/fm-rex-marks.sh 12952
bin/fm-role-lib.sh 379
bin/fm-role.sh 429
bin/fm-secondmate-charter-lib.sh 79
bin/fm-secondmate-liveness-lib.sh 10654
bin/fm-secondmate-nudge-lib.sh 178
bin/fm-secondmate-parent-lib.sh 74
bin/fm-secondmate-reconcile.sh 8748
bin/fm-secondmate-registry-lib.sh 278
bin/fm-secondmate-report.sh 29299
bin/fm-secondmate-restart-lib.sh 27545
bin/fm-secondmate-restart.sh 33800
bin/fm-secondmate-sleep-lib.sh 129
bin/fm-secondmate-sleep.sh 46144
bin/fm-send.sh 39322
bin/fm-session-lock-lib.sh 730
bin/fm-session-start.sh 28692
bin/fm-sessionstart-cursor.sh 74
bin/fm-sessionstart-nudge.sh 1381
bin/fm-sessionstart-run.sh 980
bin/fm-spawn.sh 65209
bin/fm-startup-growth-check.sh 2885
bin/fm-startup-memory-budget-lib.sh 177
bin/fm-startup-memory-budget.sh 228
bin/fm-startup-network.sh 9853
bin/fm-stow-cascade.sh 2334
bin/fm-subagent-pretool-check.sh 178
bin/fm-supervise-daemon.sh 27000
bin/fm-supervision-engine-lib.sh 328
bin/fm-supervision-handoff.sh 11457
bin/fm-supervision-host.sh 16418
bin/fm-supervision-instructions.sh 630
bin/fm-supervision-lib.sh 128
bin/fm-supervisor-target-lib.sh 76
bin/fm-t3-answer.sh 1129
bin/fm-t3code-codex-env.sh 76
bin/fm-tangle-lib.sh 78
bin/fm-task-budget-lib.sh 127
bin/fm-task-inbox-lib.sh 429
bin/fm-tasks-axi-lib.sh 179
bin/fm-tasks-axi.sh 4088
bin/fm-teardown-procevent-lib.sh 77
bin/fm-teardown.sh 76818
bin/fm-test-isolation-proof.sh 379
bin/fm-test-run.sh 2134
bin/fm-timeout-lib.sh 178
bin/fm-timing-lib.sh 129
bin/fm-tmux-lib.sh 2534
bin/fm-tool-update-check.sh 3336
bin/fm-trace-context-lib.sh 179
bin/fm-transition-lib.sh 128
bin/fm-turnend-guard-cursor.sh 10253
bin/fm-turnend-guard-grok.sh 431
bin/fm-turnend-guard.sh 9653
bin/fm-update.sh 29942
bin/fm-usage-warner.sh 12311
bin/fm-vendor-auth-probe.sh 228
bin/fm-wake-drain.sh 19026
bin/fm-wake-grant.sh 7799
bin/fm-wake-lib.sh 7648
bin/fm-watch-arm.sh 7640
bin/fm-watch-checkpoint.sh 529
bin/fm-watch.sh 60128
bin/fm-worker-account-lib.sh 324
bin/fm-x-dismiss.sh 5740
bin/fm-x-followup.sh 13913
bin/fm-x-lib.sh 5089
bin/fm-x-link.sh 16918
bin/fm-x-poll.sh 16869
bin/fm-x-reply.sh 6395
tests/cmux-test-safety.sh 79
tests/fixtures.sh 576
tests/fm-afk-contract.test.sh 1431
tests/fm-afk-inject-e2e.test.sh 229
tests/fm-afk-inject-herdr-e2e.test.sh 379
tests/fm-afk-launch.test.sh 23693
tests/fm-afk-pi-herdr-return-e2e.test.sh 879
tests/fm-afk-return.test.sh 3933
tests/fm-agy-harness.test.sh 1431
tests/fm-agy-signals-live-e2e.test.sh 831
tests/fm-approval-failover.test.sh 3537
tests/fm-arm-pretool-check.test.sh 876
tests/fm-ask-user-authority.test.sh 628
tests/fm-backend-autodetect-smoke.test.sh 230
tests/fm-backend-cmux-smoke.test.sh 178
tests/fm-backend-cmux.test.sh 7243
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh 779
tests/fm-backend-herdr-eventwait-smoke.test.sh 229
tests/fm-backend-herdr-focus-flash-e2e.test.sh 378
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh 580
tests/fm-backend-herdr-presentation-e2e.test.sh 3837
tests/fm-backend-herdr-prune-safety-e2e.test.sh 229
tests/fm-backend-herdr-respawn-idem-e2e.test.sh 179
tests/fm-backend-herdr-smoke.test.sh 429
tests/fm-backend-herdr-stale-active-tab-e2e.test.sh 129
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh 330
tests/fm-backend-herdr.test.sh 52759
tests/fm-backend-orca.test.sh 2433
tests/fm-backend-paseo-smoke.test.sh 178
tests/fm-backend-paseo.test.sh 15667
tests/fm-backend-rex-composer-live-e2e.test.sh 879
tests/fm-backend-rex-eventwait-smoke.test.sh 429
tests/fm-backend-rex-smoke.test.sh 380
tests/fm-backend-rex.test.sh 1577
tests/fm-backend-t3code-live-e2e.test.sh 681
tests/fm-backend-t3code-pr-tools-live-e2e.test.sh 575
tests/fm-backend-t3code.test.sh 4439
tests/fm-backend-tern-smoke.test.sh 279
tests/fm-backend-tern.test.sh 13464
tests/fm-backend-tmux-smoke.test.sh 279
tests/fm-backend-zellij-smoke.test.sh 229
tests/fm-backend-zellij.test.sh 8048
tests/fm-backend.test.sh 2034
tests/fm-backlog-atomicity.test.sh 13517
tests/fm-backlog-handoff.test.sh 1883
tests/fm-backlog-read-bound.test.sh 726
tests/fm-bearings-board-lavish-live-e2e.test.sh 679
tests/fm-bearings-board-render.test.sh 831
tests/fm-bearings-board.test.sh 1127
tests/fm-bearings-snapshot.test.sh 3988
tests/fm-bootstrap-network-parallel.test.sh 1231
tests/fm-bootstrap.test.sh 1627
tests/fm-branch-supervision.test.sh 2485
tests/fm-brief-test-scope.test.sh 780
tests/fm-brief.test.sh 12156
tests/fm-busy-adapter-wiring.test.sh 1883
tests/fm-busy-state.test.sh 1281
tests/fm-calm-claude-mod-live-e2e.test.sh 1030
tests/fm-calm-claude-mod-plugin.test.sh 630
tests/fm-calm-claude-mod.test.sh 931
tests/fm-calm-pi-extension.test.sh 3037
tests/fm-calm-pi-queue-retention-live-e2e.test.sh 628
tests/fm-capacity.test.sh 1231
tests/fm-captain-hold-lifecycle.test.sh 6491
tests/fm-cd-pretool-check.test.sh 1031
tests/fm-check-unregister.test.sh 779
tests/fm-ci-workflow.test.sh 675
tests/fm-classify-corr-token.test.sh 5743
tests/fm-classify-decision-key.test.sh 3833
tests/fm-claude-stop-autoarm-live-e2e.test.sh 780
tests/fm-claude-stop-autoarm.test.sh 2583
tests/fm-claude-trust.test.sh 1482
tests/fm-cmux-claude-composer-live-e2e.test.sh 1781
tests/fm-codex-continuity-live-e2e.test.sh 631
tests/fm-codex-hook-layer-live-e2e.test.sh 779
tests/fm-commandcode-harness.test.sh 4985
tests/fm-commandcode-signals-live-e2e.test.sh 5391
tests/fm-composer-codex-idle-live-e2e.test.sh 679
tests/fm-composer-ghost.test.sh 1026
tests/fm-composer-lib.test.sh 2234
tests/fm-composer-matrix-live-e2e.test.sh 726
tests/fm-contributions.test.sh 2987
tests/fm-control-herdr-smoke.test.sh 826
tests/fm-control-relaunch.test.sh 23130
tests/fm-control.test.sh 10453
tests/fm-cortex-harness.test.sh 6194
tests/fm-cortex-signals-live-e2e.test.sh 5242
tests/fm-crew-state.test.sh 7549
tests/fm-cursor-harness.test.sh 8953
tests/fm-cursor-primary-live-e2e.test.sh 729
tests/fm-cursor-primary.test.sh 1483
tests/fm-daemon.test.sh 40434
tests/fm-devin-harness.test.sh 5290
tests/fm-devin-signals-live-e2e.test.sh 5691
tests/fm-dispatch-resolve.test.sh 2985
tests/fm-documentation-audiences.test.sh 680
tests/fm-dod-lib.test.sh 11858
tests/fm-ensure-agents-md.test.sh 1030
tests/fm-extension-binding.test.sh 7845
tests/fm-fleet-ledger.test.sh 19882
tests/fm-fleet-snapshot-contribution-input.test.sh 629
tests/fm-fleet-snapshot-view.test.sh 5042
tests/fm-fleet-sync.test.sh 1027
tests/fm-forge-detect.test.sh 678
tests/fm-fork-free-helpers.test.sh 730
tests/fm-gate-refuse.test.sh 1126
tests/fm-gemini-harness.test.sh 1031
tests/fm-git-push-guard.test.sh 730
tests/fm-git-strip-ai-trailers.test.sh 1181
tests/fm-gitignore-config.test.sh 128
tests/fm-gotmp.test.sh 228
tests/fm-grok-continuity-live-e2e.test.sh 679
tests/fm-grok-harness.test.sh 933
tests/fm-grok-stop-live-e2e.test.sh 829
tests/fm-guard-stale-banner.test.sh 1531
tests/fm-harness-adapter-instructions-live-e2e.test.sh 1079
tests/fm-harness-adapter-references.test.sh 579
tests/fm-harness-liveness-drift-live-e2e.test.sh 780
tests/fm-harness-precedence.test.sh 1231
tests/fm-herdr-attached-viewer-live-e2e.test.sh 831
tests/fm-herdr-groups.test.sh 1030
tests/fm-herdr-lab.test.sh 1234
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh 729
tests/fm-herdr-session-cleanup-e2e.test.sh 177
tests/fm-herdr-session-cleanup.test.sh 1181
tests/fm-herdr-submit-confirm-live-e2e.test.sh 1231
tests/fm-herdr-version-floor-live-e2e.test.sh 833
tests/fm-home-summary-refresh.test.sh 1732
tests/fm-host-mirror-live-e2e.test.sh 4239
tests/fm-host-mirror.test.sh 826
tests/fm-inactive-reconcile.test.sh 1733
tests/fm-inbox.test.sh 1382
tests/fm-jev-mem-guard.test.sh 129
tests/fm-kimi-delivery-live-e2e.test.sh 729
tests/fm-kimi-harness.test.sh 1928
tests/fm-kimi-trust-prompt-live-e2e.test.sh 880
tests/fm-launch-mise-env.test.sh 127
tests/fm-launch-prompt-signals-live-e2e.test.sh 68703
tests/fm-lint-workflows.test.sh 980
tests/fm-lint.test.sh 2484
tests/fm-live-gate.test.sh 876
tests/fm-live-lab-up-mate.test.sh 780
tests/fm-live-lab.test.sh 1933
tests/fm-local-handoff.test.sh 2487
tests/fm-mail-check.test.sh 1029
tests/fm-mail.test.sh 2433
tests/fm-muse-harness.test.sh 3937
tests/fm-muse-signals-live-e2e.test.sh 4839
tests/fm-nm-respond.test.sh 127
tests/fm-nm-test-contract.test.sh 579
tests/fm-no-mistakes-required.test.sh 629
tests/fm-omp-harness.test.sh 6944
tests/fm-omp-primary-live-e2e.test.sh 880
tests/fm-on.test.sh 3538
tests/fm-opencode-abs-cwd-rail-live-e2e.test.sh 680
tests/fm-opencode-primary-live-e2e.test.sh 1031
tests/fm-operational-input.test.sh 830
tests/fm-pane-question-detector.test.sh 1081
tests/fm-parent-channel-scan-exclusion.test.sh 880
tests/fm-peek-remote.test.sh 679
tests/fm-pending-reply.test.sh 93816
tests/fm-pi-branch-extension.test.sh 1882
tests/fm-pi-branch-live-e2e.test.sh 776
tests/fm-pi-branch-responsiveness-live-e2e.test.sh 780
tests/fm-pi-codex-native.test.sh 631
tests/fm-pi-primary-live-e2e.test.sh 1034
tests/fm-pi-primary-types.test.sh 128
tests/fm-pi-seeded-home-trust-live-e2e.test.sh 728
tests/fm-pi-watch-extension.test.sh 2535
tests/fm-pi-windows-shell-invocation.test.sh 682
tests/fm-pipeline-spend.test.sh 981
tests/fm-polytoken-harness.test.sh 1683
tests/fm-polytoken-signals-live-e2e.test.sh 4934
tests/fm-pr-check-security.test.sh 4488
tests/fm-pr-health.test.sh 1181
tests/fm-pr-merge.test.sh 5090
tests/fm-pr-review.test.sh 1582
tests/fm-pr-reviewers.test.sh 629
tests/fm-pr-state-live-e2e.test.sh 580
tests/fm-pr-state.test.sh 831
tests/fm-procevent-quota.test.sh 380
tests/fm-procevent-retire-task.test.sh 12908
tests/fm-procevent-when.test.sh 3788
tests/fm-procevent.test.sh 18274
tests/fm-project-capacity.test.sh 1231
tests/fm-project-mode.test.sh 679
tests/fm-project-origin.test.sh 730
tests/fm-public-followup.test.sh 24843
tests/fm-quota-array-dispatch-live-e2e.test.sh 680
tests/fm-quota-choose.test.sh 479
tests/fm-record-export-remote-home.test.sh 679
tests/fm-record-export.test.sh 1632
tests/fm-remote-backlog-handoff.test.sh 1380
tests/fm-remote-delta-read.test.sh 830
tests/fm-remote-doctor.test.sh 1483
tests/fm-remote-entrypoint.test.sh 630
tests/fm-remote-herdr-guard.test.sh 1031
tests/fm-remote-job-claim-reap.test.sh 5244
tests/fm-remote-job-claim-retention.test.sh 2533
tests/fm-remote-job-launchagent.test.sh 3085
tests/fm-remote-job-orphan-reap.test.sh 831
tests/fm-remote-job-process-start.test.sh 3087
tests/fm-remote-job.test.sh 10595
tests/fm-remote-reply.test.sh 36816
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 5443
tests/fm-remote-secondmate-parent-binding.test.sh 880
tests/fm-remote-secondmate-relaunch.test.sh 2833
tests/fm-remote-secondmate-trace-context.test.sh 930
tests/fm-remote-transport-lanes.test.sh 3638
tests/fm-review-check.test.sh 679
tests/fm-review-diff.test.sh 831
tests/fm-rovo-harness.test.sh 4290
tests/fm-rovo-signals-live-e2e.test.sh 1227
tests/fm-secondmate-busy-contract-live-e2e.test.sh 1833
tests/fm-secondmate-harness.test.sh 3837
tests/fm-secondmate-lifecycle-e2e.test.sh 1030
tests/fm-secondmate-liveness.test.sh 1280
tests/fm-secondmate-reconcile.test.sh 1834
tests/fm-secondmate-restart.test.sh 1582
tests/fm-secondmate-safety.test.sh 4189
tests/fm-secondmate-sleep.test.sh 1031
tests/fm-secondmate-sync.test.sh 2629
tests/fm-self-repo-role.test.sh 1480
tests/fm-send-agy-confirm.test.sh 680
tests/fm-send-inbox-doorbell-live-e2e.test.sh 780
tests/fm-send-inbox.test.sh 876
tests/fm-send-popup-settle.test.sh 680
tests/fm-send-remote-delivery.test.sh 30054
tests/fm-send-resolve-key.test.sh 1632
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 729
tests/fm-send-secondmate-marker.test.sh 775
tests/fm-send-settle.test.sh 679
tests/fm-send-strict.test.sh 1030
tests/fm-session-lock-ancestry.test.sh 1882
tests/fm-session-start.test.sh 4088
tests/fm-sessionstart-hook-live-e2e.test.sh 1030
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 780
tests/fm-sessionstart-nudge.test.sh 1181
tests/fm-shared-captain-inheritance.test.sh 1026
tests/fm-spawn-batch.test.sh 678
tests/fm-spawn-compact-adviser-disable-remote.test.sh 781
tests/fm-spawn-compact-adviser-disable.test.sh 1132
tests/fm-spawn-dispatch-profile.test.sh 4139
tests/fm-spawn-external-review.test.sh 879
tests/fm-spawn-orca-worktree.test.sh 1632
tests/fm-spawn-pool-base-freshen.test.sh 1979
tests/fm-spawn-worktree-settle.test.sh 930
tests/fm-startup-growth-check.test.sh 3537
tests/fm-startup-memory-budget.test.sh 880
tests/fm-startup-network.test.sh 1784
tests/fm-stat-shadowing.test.sh 72124
tests/fm-stow-cascade.test.sh 981
tests/fm-subagent-pretool-check.test.sh 882
tests/fm-supervision-events.test.sh 831
tests/fm-supervision-host-attended-live-e2e.test.sh 4890
tests/fm-supervision-host-late.test.sh 1982
tests/fm-supervision-host-live-e2e.test.sh 781
tests/fm-supervision-host.test.sh 4841
tests/fm-supervision-instructions.test.sh 980
tests/fm-t3-mcp.test.sh 1782
tests/fm-tangle-guard.test.sh 930
tests/fm-task-budget.test.sh 780
tests/fm-task-delivery.test.sh 2536
tests/fm-task-inbox.test.sh 2234
tests/fm-tasks-axi.test.sh 778
tests/fm-teardown-endpoint-safety.test.sh 2385
tests/fm-teardown-procevent.test.sh 13565
tests/fm-teardown.test.sh 6096
tests/fm-test-fixture-cleanup.test.sh 780
tests/fm-test-fixtures.test.sh 926
tests/fm-test-isolation-proof.test.sh 831
tests/fm-test-run.test.sh 2685
tests/fm-timeout-lib.test.sh 2279
tests/fm-tmux-agent-liveness.test.sh 4489
tests/fm-tmux-submit-busy.test.sh 1031
tests/fm-tool-update-check.test.sh 1732
tests/fm-trace-context-lib.test.sh 881
tests/fm-trace-context-spawn.test.sh 1130
tests/fm-transition-lib.test.sh 730
tests/fm-treehouse-clone-custody.test.sh 881
tests/fm-turnend-foreign-owner-arm-fix.test.sh 78
tests/fm-turnend-guard.test.sh 3136
tests/fm-update.test.sh 876
tests/fm-usage-warner.test.sh 1182
tests/fm-vendor-auth-probe.test.sh 725
tests/fm-voice-relay.test.sh 1833
tests/fm-wake-daemon-lifecycle-e2e.test.sh 982
tests/fm-wake-drain-open-decisions-cursor.test.sh 1281
tests/fm-wake-drain-open-decisions.test.sh 931
tests/fm-wake-drain-outcome-backstop.test.sh 1331
tests/fm-wake-drain-unread-status.test.sh 1180
tests/fm-wake-queue.test.sh 4939
tests/fm-watch-arm.test.sh 2935
tests/fm-watch-beacon.test.sh 726
tests/fm-watch-checkpoint.test.sh 1131
tests/fm-watch-inbox-meta.test.sh 579
tests/fm-watch-recovery-loop.test.sh 1082
tests/fm-watch-triage-late.test.sh 5141
tests/fm-watch-triage.test.sh 7147
tests/fm-watch-wedge-cap-live.test.sh 1732
tests/fm-watch-wedge-cap-unconfigured-parity.test.sh 876
tests/fm-watch-wedge-cap.test.sh 3035
tests/fm-watcher-lock.test.sh 2734
tests/fm-worker-account-live-e2e.test.sh 1130
tests/fm-worker-account.test.sh 1281
tests/fm-x-mode.test.sh 4792
tests/git-config-helpers.sh 78
tests/herdr-client-pair-fixture.sh 78
tests/herdr-test-safety.sh 78
tests/lib.sh 531
tests/remote-herdr-fixture.sh 79
tests/rex-test-safety.sh 228
tests/secondmate-helpers.sh 630
tests/secondmate-persist-helpers.sh 129
tests/supervision-host-helpers.sh 1031
tests/t3-fake-lib.sh 127
tests/tern-test-safety.sh 78
tests/wake-helpers.sh 730
tests/watch-triage-helpers.sh 875
tests/zellij-test-safety.sh 76
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
    weight=1
    if [ -f "$path" ]; then
      weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
    printf '%s\t%s\t%s\n' "$weight" "$index" "$path"
    index=$((index + 1))
  done
}

if [ -n "$PARTITION" ]; then
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
  ROOTS=("${PARTITION_ROOTS[@]}")
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
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
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

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_backend_purity || overall_rc=$?
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
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
# never lints uncapped. Without it each root still runs alone in its own
# ShellCheck process, unbounded, for local developer lint.
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
# inside the 16 GiB runner. Local lint defaults to two workers; two such
# caps allow ~16 GiB resident plus host overhead, so use FM_LINT_JOBS=1 on
# smaller local machines. A root that exceeds its cap fails by name.
# Never disable, narrow, or redirect source-following to fit a root under
# the cap. The roots sidecar records each root's peak RSS; roots peaking
# above about 3 GiB resident are reduction candidates,
# bin/fm-pending-reply-lib.sh first (its separate dedup fix is PR 5753).
ROOT_MEMORY_KIB=${FM_LINT_ROOT_MEMORY_KIB:-12582912}
for bound_pair in \
  "FM_LINT_ROOT_SECONDS=$ROOT_SECONDS" \
  "FM_LINT_ROOT_GRACE=$ROOT_GRACE" \
  "FM_LINT_ROOT_MEMORY_KIB=$ROOT_MEMORY_KIB"; do
  case "${bound_pair#*=}" in
    ''|0*|*[!0-9]*)
      printf 'fm-lint.sh: %s must be a positive integer, got %s.\n' \
        "${bound_pair%%=*}" "${bound_pair#*=}" >&2
      exit 2
      ;;
  esac
done

BOUND_MECH=none
if [ "${FM_LINT_REQUIRE_BOUNDS:-0}" = 1 ]; then
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

SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_root_weights > "$WEIGHTS" || exit $?

# Largest-first deterministic greedy assignment balances the two worker
# queues without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
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
        /usr/bin/time -lp -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env "${worker_env[@]}" \
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
overall_rc=0
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

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  source_followed=0
  awk -F '\t' '$1 == "end" && $12 == 0 { print $2 }' "$ROOTS_LOG" > "$TMP_ROOT/no-source-indices"
  root_index=0
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
