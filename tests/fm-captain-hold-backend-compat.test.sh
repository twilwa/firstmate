#!/usr/bin/env bash
# Backend compatibility at the captain-call completion/verification CLI seam.
# All tasks-axi and native backend calls are stubs; no installed backend is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-backend-compat)
HOLD="$ROOT/bin/fm-captain-hold.sh"

make_compat_home() {  # <name> <backend> [binary]
  local home="$TMP_ROOT/$1" backend=$2 binary=${3:-br}
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/fakebin" "$home/rows" "$home/graph"
  printf 'backend = "%s"\n' "$backend" > "$home/.tasks.toml"
  if [ "$backend" = beads ]; then
    printf '\n[beads]\npath = "graph"\nprefix = "fm"\n' >> "$home/.tasks.toml"
    case "$binary" in
      absolute-br) binary="$home/fakebin/br" ;;
      absolute-bd) binary="$home/fakebin/bd" ;;
    esac
    [ "$binary" = default-bd ] || printf 'binary = "%s"\n' "$binary" >> "$home/.tasks.toml"
  elif [ "$backend" = markdown ]; then
    printf '\n[markdown]\npath = "data/backlog.md"\narchive = "data/answered.md"\n' >> "$home/.tasks.toml"
  fi
  printf 'kind=scout\nmode=scout\n' > "$home/state/origin.meta"
  printf '[]\n' > "$home/graph.json"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tasks-axi %s\n' "$*" >> "$FM_TEST_COMPAT_HOME/calls"
case "${1:-}" in
  --version) printf '0.2.6\n' ;;
  update) [ "${2:-}" = --help ] || exit 90; printf '%s\n' '--archive-body --body-file' ;;
  mv) [ "${2:-}" = --help ] || exit 90; printf '%s\n' '[<id>...] --to' ;;
  hold) [ "${2:-}" = --help ] || exit 90; printf '%s\n' '--kind captain --until' ;;
  show)
    id=${2:-}
    shift 2
    file=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --full) ;;
        --file) shift; file=${1:-} ;;
        *) exit 91 ;;
      esac
      shift
    done
    if [ -n "$file" ]; then
      # Only a staged markdown archive replay can return an archived row.
      if [ "$file" != "$FM_TEST_COMPAT_HOME/data/backlog.md" ] \
        && [ -f "$file" ] && grep -Fq -- "- [x] $id " "$file"; then
        cat "$FM_TEST_COMPAT_HOME/archive-row"
        exit 0
      fi
    else
      [ "$PWD" = "$FM_TEST_COMPAT_HOME" ] || exit 92
      [ ! -f "$FM_TEST_COMPAT_HOME/rows/$id.timeout" ] || exit 124
      if [ -f "$FM_TEST_COMPAT_HOME/rows/$id" ]; then
        cat "$FM_TEST_COMPAT_HOME/rows/$id"
        exit 0
      fi
    fi
    printf 'code: NOT_FOUND\n'
    exit 1
    ;;
  *) exit 93 ;;
esac
SH
  cat > "$home/fakebin/br" <<'SH'
#!/usr/bin/env bash
# This stub never opens a database or delegates to an installed binary.
printf 'unexpected native lookup: %s\n' "$*" >> "$FM_TEST_COMPAT_HOME/native-calls"
exit 94
SH
  cat > "$home/fakebin/bd" <<'SH'
#!/usr/bin/env bash
[ "${BEADS_DIR:-}" = "$FM_TEST_COMPAT_HOME/graph" ] || exit 95
[ "$*" = 'list --all --json' ] || exit 96
printf 'bd %s\n' "$*" >> "$FM_TEST_COMPAT_HOME/native-calls"
cat "$FM_TEST_COMPAT_HOME/graph.json"
SH
  chmod +x "$home/fakebin/tasks-axi" "$home/fakebin/br" "$home/fakebin/bd"
  printf '%s\n' "$home"
}

compat_row() {  # <home> <lookup-id> <shown-id> <answered|unanswered|deferred|held>
  local home=$1 lookup=$2 id=$3 mode=$4 body state='done' hold_kind=-
  case "$mode" in
    answered|deferred)
      body=$(printf 'Resolution recorded by fm-captain-hold.\nResolution mode: %s\nCaptain decision:\nProceed.\nCaptain hold origin: origin\n' "$mode")
      ;;
    unanswered) body='Closed without a recorded answer.' ;;
    held) body='Captain hold origin: origin'; state=queued; hold_kind=captain ;;
  esac
  {
    printf 'task:\n  id: %s\n  state: %s\n  hold_kind: %s\n' "$id" "$state" "$hold_kind"
    printf '  body: %s\n' "$(printf '%s' "$body" | jq -Rs .)"
  } > "$home/rows/$lookup"
}

run_compat() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$BASE_PATH" FM_TEST_COMPAT_HOME="$home" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    bash "$HOLD" "$@"
}

attest_compat() {  # <home> <entry>
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$2" >> "$1/state/origin.meta"
}

test_closed_answer_uses_show_on_nonmarkdown_backends() {
  local backend home out
  for backend in beads sqlite; do
    home=$(make_compat_home "answered-$backend" "$backend")
    # A slug-mapping adapter accepts the external reference and returns its id.
    compat_row "$home" held-call slug-abc answered
    out=$(run_compat "$home" complete origin held-call 2>&1) || fail "$backend complete: $out"
    out=$(run_compat "$home" verify origin 2>&1) || fail "$backend verify: $out"
    grep -q '^tasks-axi show held-call --full$' "$home/calls" || fail "$backend never showed the closed call"
    ! grep -q -- '--file' "$home/calls" || fail "$backend was overridden with a markdown file"
    [ ! -e "$home/native-calls" ] || fail "$backend bypassed tasks-axi for a known row"
  done
  pass "closed answered calls use tasks-axi show on non-markdown backends, including slug-mapped ids"
}

test_closed_rows_require_a_non_deferred_answer() {
  local mode home out status
  for mode in unanswered deferred; do
    home=$(make_compat_home "$mode" beads)
    compat_row "$home" held-call slug-abc "$mode"
    status=0
    out=$(run_compat "$home" complete origin held-call 2>&1) || status=$?
    [ "$status" = 1 ] || fail "$mode completion returned $status: $out"
    ! grep -q '^decisions_reviewed=1$' "$home/state/origin.meta" || fail "$mode was attested"
    attest_compat "$home" held-call
    status=0
    out=$(run_compat "$home" verify origin 2>&1) || status=$?
    [ "$status" = 1 ] || fail "$mode verification returned $status: $out"
    [ ! -e "$home/native-calls" ] || fail "$mode triggered a native lookup"
  done
  pass "closed rows without an answer or carrying only a deferral cannot satisfy completion or verification"
}

test_slug_backends_do_not_rehome_missing_calls() {
  local binary home out status
  for binary in br absolute-br; do
    home=$(make_compat_home "missing-$binary" beads "$binary")
    # Neither the old prefix nor a stale markdown mirror may rescue a missing id.
    compat_row "$home" fm-missing fm-missing held
    printf '## Done\n- [x] missing Stale markdown mirror\n' > "$home/data/answered.md"
    status=0
    out=$(run_compat "$home" complete origin missing 2>&1) || status=$?
    [ ! -e "$home/native-calls" ] || fail "$binary completion attempted a native migration scan: $out"
    [ "$status" = 1 ] || fail "$binary missing completion returned $status: $out"
    attest_compat "$home" missing
    status=0
    out=$(run_compat "$home" verify origin 2>&1) || status=$?
    [ ! -e "$home/native-calls" ] || fail "$binary verification attempted a native migration scan: $out"
    [ "$status" = 1 ] || fail "$binary missing verification returned $status: $out"
    ! grep -q 'show fm-missing' "$home/calls" || fail "$binary guessed a prefixed identity"
    ! grep -q -- '--file' "$home/calls" || fail "$binary read a markdown mirror"
  done
  pass "slug-mapped backends leave missing calls missing without a native scan or prefixed-id guess"
}

test_env_selected_non_bd_skips_migration_lookup() {
  local variant home out status
  for variant in env-binary-br env-backend-no-binary; do
    home=$(make_compat_home "env-$variant" beads default-bd)
    compat_row "$home" fm-missing fm-missing held
    printf '%s\n' '[{"id":"fm-missing","notes":"migrated from data/backlog.md id missing"}]' > "$home/graph.json"
    set -- TASKS_AXI_BEADS_BINARY=br
    if [ "$variant" = env-backend-no-binary ]; then
      # The root file keeps markdown; beads is selected only by the override.
      sed -i 's/^backend = "beads"$/backend = "markdown"/' "$home/.tasks.toml"
      set -- TASKS_AXI_BACKEND=beads
    fi
    status=0
    out=$(export "$@"; run_compat "$home" complete origin missing 2>&1) || status=$?
    [ ! -e "$home/native-calls" ] || fail "$variant completion attempted a native migration scan: $out"
    [ "$status" = 1 ] || fail "$variant missing completion returned $status: $out"
    assert_contains "$out" 'no captain-held task' "$variant completion must report a clean absence"
    attest_compat "$home" missing
    status=0
    out=$(export "$@"; run_compat "$home" verify origin 2>&1) || status=$?
    [ ! -e "$home/native-calls" ] || fail "$variant verification attempted a native migration scan: $out"
    [ "$status" = 1 ] || fail "$variant missing verification returned $status: $out"
    ! grep -q 'show fm-missing' "$home/calls" || fail "$variant guessed a prefixed identity"
  done
  pass "a non-bd binary or beads backend selected outside the root config skips the legacy migration lookup"
}

test_bd_migration_lookup_is_preserved() {
  local binary home out
  for binary in bd absolute-bd default-bd; do
    home=$(make_compat_home "legacy-$binary" beads "$binary")
    compat_row "$home" fm-missing fm-missing held
    printf '%s\n' '[{"id":"fm-missing","notes":"migrated from data/backlog.md id missing"}]' > "$home/graph.json"
    out=$(run_compat "$home" complete origin missing 2>&1) || fail "$binary migrated completion: $out"
    out=$(run_compat "$home" verify origin 2>&1) || fail "$binary migrated verification: $out"
    grep -q '^bd list --all --json$' "$home/native-calls" || fail "$binary did not read its configured graph"
  done
  pass "legacy bd migration markers still resolve with default, named, and absolute bd binaries"
}

test_env_addressed_bd_lookup_uses_env_path_and_prefix() {
  local home out status
  home=$(make_compat_home env-addressed beads default-bd)
  # The root file keeps markdown and a stale graph; the selector env addresses the real one.
  printf 'backend = "markdown"\n\n[beads]\npath = "stale"\nprefix = "fm"\n' > "$home/.tasks.toml"
  compat_row "$home" fx-missing fx-missing held
  set -- TASKS_AXI_BACKEND=beads TASKS_AXI_BEADS_BINARY=bd \
    "TASKS_AXI_BEADS_PATH=$home/graph" TASKS_AXI_BEADS_PREFIX=fx
  out=$(export "$@"; run_compat "$home" complete origin missing 2>&1) || fail "env-addressed completion: $out"
  out=$(export "$@"; run_compat "$home" verify origin 2>&1) || fail "env-addressed verification: $out"
  grep -q '^bd list --all --json$' "$home/native-calls" || fail "env-addressed lookup did not scan the env graph"
  grep -q '^tasks-axi show fx-missing' "$home/calls" || fail "env-addressed lookup ignored TASKS_AXI_BEADS_PREFIX"
  ! grep -q 'show fm-missing' "$home/calls" || fail "env-addressed lookup used the root prefix"

  home=$(make_compat_home env-relative beads default-bd)
  compat_row "$home" fm-missing fm-missing held
  status=0
  out=$(export TASKS_AXI_BEADS_PATH=graph; run_compat "$home" complete origin missing 2>&1) || status=$?
  [ "$status" != 0 ] || fail "a relative TASKS_AXI_BEADS_PATH was accepted: $out"
  assert_contains "$out" 'TASKS_AXI_BEADS_PATH must be an absolute path' 'a relative env path must be refused by name'
  [ ! -e "$home/native-calls" ] || fail "a relative TASKS_AXI_BEADS_PATH was scanned"
  ! grep -q '^decisions_reviewed=1$' "$home/state/origin.meta" || fail "a relative env path was attested"
  pass "the legacy bd lookup takes its graph path and prefix from the env first and refuses a relative env path"
}

test_markdown_done_archive_is_preserved() {
  local home out
  home=$(make_compat_home archived markdown)
  compat_row "$home" held-call held-call answered
  mv "$home/rows/held-call" "$home/archive-row"
  printf '## Done\n' > "$home/data/backlog.md"
  printf '## Done\n- [x] held-call Answered call\n' > "$home/data/answered.md"
  out=$(run_compat "$home" complete origin held-call 2>&1) || fail "markdown archived completion: $out"
  out=$(run_compat "$home" verify origin 2>&1) || fail "markdown archived verification: $out"
  grep -q -- '--file .*/backlog.md' "$home/calls" || fail "markdown never replayed its archive"
  [ ! -e "$home/native-calls" ] || fail "markdown invoked a native backend"
  pass "markdown completion and verification still replay their configured Done archive"
}

test_show_timeout_is_not_absence() {
  local home out status
  home=$(make_compat_home timeout beads)
  : > "$home/rows/held-call.timeout"
  status=0
  out=$(run_compat "$home" complete origin held-call 2>&1) || status=$?
  [ "$status" != 0 ] || fail "completion accepted a timed-out read: $out"
  assert_contains "$out" 'exceeded its read bound' 'completion must report the read bound, not a missing row'
  ! grep -q '^decisions_reviewed=1$' "$home/state/origin.meta" || fail "timed-out call was attested"
  attest_compat "$home" held-call
  status=0
  out=$(run_compat "$home" verify origin 2>&1) || status=$?
  [ "$status" != 0 ] || fail "verification accepted a timed-out read: $out"
  assert_contains "$out" 'exceeded its read bound' 'verification must report the read bound, not a missing row'
  [ ! -e "$home/native-calls" ] || fail "timeout triggered a native fallback"
  ! grep -q -- '--file' "$home/calls" || fail "timeout triggered an archive fallback"
  ! grep -q 'show origin-decision-' "$home/calls" || fail "timeout triggered a legacy-id fallback"
  pass "tasks-axi show timeout stops completion and verification without archive or migration fallback"
}

fm_test_run \
  test_closed_answer_uses_show_on_nonmarkdown_backends \
  test_closed_rows_require_a_non_deferred_answer \
  test_slug_backends_do_not_rehome_missing_calls \
  test_env_selected_non_bd_skips_migration_lookup \
  test_bd_migration_lookup_is_preserved \
  test_env_addressed_bd_lookup_uses_env_path_and_prefix \
  test_markdown_done_archive_is_preserved \
  test_show_timeout_is_not_absence
