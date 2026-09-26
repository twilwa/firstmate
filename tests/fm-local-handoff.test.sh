#!/usr/bin/env bash
# tests/fm-local-handoff.test.sh - local-only secondmate custody, end to end:
# the bound seed clone and its binding record, the child's head-pinned landing
# offer, the primary's guarded delegated fast-forward and its landing receipt,
# the idempotent receipt recovery, and the teardown gate that only a durable,
# independently re-proved receipt opens.
#
# Every case drives the real scripts against isolated temporary homes built by
# make_bound_fixture below; nothing here reaches a forge, a remote, a shared
# object store, or a live agent. The seed-refusal invariants that used to live
# in fm-secondmate-safety.test.sh's local-only case moved here with the
# behavior: a local-only project is now seeded as a bound child copy instead of
# being refused, while fm-remote-secondmate-lifecycle-e2e.test.sh still owns the
# unchanged whole-home remote refusal.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-handoff)

# These homes carry no .tasks.toml, so an unpinned backend would resolve
# against whatever the host operator configured. Pin the tracked markdown
# default: with no data/backlog.md beside it, the captain-hold check every
# landing runs reads this fixture's own absent backlog rather than a live one.
export TASKS_AXI_BACKEND=markdown

SEED="$ROOT/bin/fm-home-seed.sh"
HANDOFF="$ROOT/bin/fm-local-handoff.sh"
MERGE="$ROOT/bin/fm-merge-local.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

# Run a firstmate script with every operational path pinned inside <home>, so
# no case can resolve the operator's own state, data, or project clones.
run_home() {  # <home> <script> [args...]
  local home=$1 script=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_CONFIG_OVERRIDE="$home/config" \
  PATH="$home/fakebin:$PATH" \
    "$script" "$@"
}

# Build one primary home holding a local-only project, seed it into a
# secondmate home as a bound clone, and give that child a local-only task on
# its own worktree of the bound copy. Reports through globals because several
# cases need every path it resolves.
FX_MAIN=
FX_CHILD=
FX_TASK=
FX_WT=
FX_CLONE=
FX_OFFER=
make_bound_fixture() {  # <name> [task-id]
  local name=$1 task=${2:-child-task} fx main child fakebin
  fx="$TMP_ROOT/$name"
  main="$fx/main"
  child="$fx/child"
  mkdir -p "$main/projects" "$main/data" "$main/state" "$main/config"
  fm_git_init_commit "$main/projects/app"
  printf '%s\n' '- app [local-only] - app project (added 2026-06-22)' \
    > "$main/data/projects.md"
  # A prepared minimal home keeps the seed from cloning the whole firstmate
  # repo for every case; its own home validation still runs against it.
  mark_firstmate_home "$child"
  fakebin=$(fm_fakebin "$child")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  FM_HOME="$main" FM_SECONDMATE_CHARTER='local app work' \
    FM_SECONDMATE_SCOPE='local app work' \
    "$SEED" localsub "$child" app >/dev/null \
    || fail "$name: seeding the local-only secondmate home failed"
  # The parent's own launch record for the secondmate; teardown in the child
  # home resolves its primary through it.
  fm_write_secondmate_meta "$main/state/localsub.meta" "$child" firstmate:fm-localsub app

  FX_MAIN=$main
  FX_CHILD=$child
  FX_TASK=$task
  FX_CLONE="$child/projects/app"
  FX_WT="$child/work/$task"
  FX_OFFER="$child/state/$task.local-offer"
  mkdir -p "$child/work"
  git -C "$FX_CLONE" worktree add --quiet -b "fm/$task" "$FX_WT" \
    || fail "$name: could not add the child task worktree"
  fm_write_meta "$child/state/$task.meta" \
    "window=firstmate:fm-$task" \
    "endpoint_task_id=$task" \
    "worktree=$FX_WT" \
    "project=$FX_CLONE" \
    "harness=echo" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off" \
    "spawn_gen=7"
  touch "$child/state/.last-watcher-beat" "$main/state/.last-watcher-beat"
}

# Commit <text> on the child task's branch through its own worktree.
commit_child_work() {  # <text>
  printf '%s\n' "$1" > "$FX_WT/work.txt"
  git -C "$FX_WT" add work.txt
  git -C "$FX_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "$1"
}

record_field() {  # <file> <key>
  grep "^$2=" "$1" | head -1 | cut -d= -f2-
}

# The approval owner for every delegated landing is a real captain-held
# backlog row in the primary home, so these cases drive the actual
# bin/fm-captain-hold.sh lifecycle instead of simulating one. Reports 1 when
# this host's tasks-axi cannot host the row, so a case can skip that half
# rather than assert against a capability it does not have.
FX_LANDING=
FX_LANDING_RECORD=
prepare_landing_row() {  # <landing-id>
  FX_LANDING=$1
  FX_LANDING_RECORD="$FX_MAIN/data/local-only-landings/$FX_LANDING.landing"
  command -v tasks-axi >/dev/null 2>&1 || return 1
  cp "$ROOT/.tasks.toml" "$FX_MAIN/.tasks.toml"
  # Keep rows a case already filed: an approval is immutable, so a second head
  # needs a second landing row beside the first, not a rewritten backlog.
  [ -f "$FX_MAIN/data/backlog.md" ] \
    || printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$FX_MAIN/data/backlog.md"
  (cd "$FX_MAIN" && tasks-axi add "$FX_LANDING" "Land the child's offered work" \
    --kind ship --start) >/dev/null 2>&1 || return 1
  hold_landing_row
}

hold_landing_row() {
  run_home "$FX_MAIN" "$ROOT/bin/fm-captain-hold.sh" hold "$FX_LANDING" \
    --reason "captain approval for the child landing" >/dev/null 2>&1
}

# The captain's recorded words release the call through the one answer intake;
# nothing in this custody parses that prose.
release_landing_row() {
  local words="$TMP_ROOT/$FX_LANDING.decision"
  printf 'Land the offered head.\n' > "$words"
  run_home "$FX_MAIN" "$ROOT/bin/fm-captain-hold.sh" answer "$FX_LANDING" \
    --decision-file "$words" --release >/dev/null 2>&1
}

# The whole approval path: pin the child's current offer while the row is still
# held, then record the captain's release of that exact pinned call.
approve_current_offer() {
  run_home "$FX_MAIN" "$HANDOFF" request "$FX_LANDING" --offer "$FX_OFFER" >/dev/null \
    || fail "pinning the offer to the held landing row failed"
  release_landing_row || fail "releasing the landing row failed"
}

# Write a landing receipt by hand, which is exactly what a compromised or
# confused child could do. Nothing in the product writes a receipt this way;
# only the primary's own landing does.
forge_receipt() {  # <parent-project> [landing-id]
  local parent_project=$1 landing=${2:-land-app} receipt
  receipt="$FX_CHILD/state/$FX_TASK.local-receipt"
  {
    printf 'schema=fm-local-receipt.v1\n'
    printf 'secondmate=%s\n' "$(record_field "$FX_OFFER" secondmate)"
    printf 'parent_home=%s\n' "$(record_field "$FX_OFFER" parent_home)"
    printf 'parent_project=%s\n' "$parent_project"
    printf 'project=%s\n' "$(record_field "$FX_OFFER" project)"
    printf 'task=%s\n' "$FX_TASK"
    printf 'spawn_gen=%s\n' "$(record_field "$FX_OFFER" spawn_gen)"
    printf 'head=%s\n' "$(record_field "$FX_OFFER" head)"
    printf 'default_branch=main\n'
    printf 'landing_id=%s\n' "$landing"
    printf 'landed_at=%s\n' "$(date +%s)"
  } > "$receipt"
}

# FIXTURE INSTRUMENTATION ONLY: a wrapper placed ahead of the real ln on the
# primary home's PATH. It freezes exactly one landing-record publication, on
# whichever side of the real link a case names, so a second command can be
# driven through that window on purpose. Its signal file carries the pid of
# the process publishing that record, which is what lets a case name the lock
# holder it expects. Nothing in the product reads these variables, and every
# other ln is passed straight through.
FX_RACE_AT=
FX_RACE_GO=
install_pin_pause_shim() {  # <name> <before|after>
  local name=$1 when=$2 real
  real=$(command -v ln) || fail "this host has no ln to wrap"
  FX_RACE_AT="$TMP_ROOT/$name.race-at"
  FX_RACE_GO="$TMP_ROOT/$name.race-go"
  export FX_RACE_WHEN=$when FX_RACE_AT FX_RACE_GO
  rm -f "$FX_RACE_AT" "$FX_RACE_GO"
  mkdir -p "$FX_MAIN/fakebin"
  cat > "$FX_MAIN/fakebin/ln" <<SHIM
#!/usr/bin/env bash
# FIXTURE INSTRUMENTATION ONLY (tests/fm-local-handoff.test.sh).
# The wait ends with the case that installed this wrapper, so a case that
# fails inside its own window leaves nothing frozen behind it.
wait_for_go() {
  while [ ! -e "\$FX_RACE_GO" ]; do
    kill -0 $$ 2>/dev/null || exit 1
    sleep 0.05
  done
}
dest=\${@: -1}
if [ "\${dest%.landing}" = "\$dest" ] || [ -e "\$FX_RACE_GO" ]; then
  exec $real "\$@"
fi
if [ "\$FX_RACE_WHEN" = after ]; then
  $real "\$@"
  rc=\$?
  printf '%s\n' "\$PPID" > "\$FX_RACE_AT.tmp" && mv "\$FX_RACE_AT.tmp" "\$FX_RACE_AT"
  wait_for_go
  exit "\$rc"
fi
printf '%s\n' "\$PPID" > "\$FX_RACE_AT.tmp" && mv "\$FX_RACE_AT.tmp" "\$FX_RACE_AT"
wait_for_go
exec $real "\$@"
SHIM
  chmod 0755 "$FX_MAIN/fakebin/ln"
}

# Bounded wait for a fixture signal, so a signal that never arrives fails the
# case instead of hanging the suite.
wait_for_path() {  # <path> <what> [tries]
  local path=$1 what=$2 tries=${3:-300}
  while [ "$tries" -gt 0 ]; do
    [ ! -e "$path" ] || return 0
    sleep 0.05
    tries=$((tries - 1))
  done
  fail "$what did not happen within the bounded wait"
}

# True when the process holding a lock is the process that is publishing the
# pin, or one of its ancestors, which is what distinguishes a command waiting
# on that lock from one that is merely slow.
lock_holder_is_the_publisher() {  # <lock-owner-pid> <publishing-pid>
  local owner=$1 pid=$2 hops=64
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$hops" -gt 0 ]; do
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$pid" != "$owner" ] || return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    hops=$((hops - 1))
  done
  return 1
}

# The landing row's backlog state, read through the backlog tool itself.
landing_row_state() {
  (cd "$FX_MAIN" && tasks-axi show "$FX_LANDING") 2>/dev/null \
    | sed -n 's/^  state: *//p' | head -1
}

# FIXTURE INSTRUMENTATION ONLY: a wrapper placed ahead of the real mv on the
# primary home's PATH that fails every publication of a landing receipt, which
# is how a landing whose receipt could not be written is driven on purpose.
# Every other mv is passed straight through.
install_receipt_failure_shim() {
  local real
  real=$(command -v mv) || fail "this host has no mv to wrap"
  mkdir -p "$FX_MAIN/fakebin"
  cat > "$FX_MAIN/fakebin/mv" <<SHIM
#!/usr/bin/env bash
# FIXTURE INSTRUMENTATION ONLY (tests/fm-local-handoff.test.sh).
dest=\${@: -1}
[ "\${dest%.local-receipt}" = "\$dest" ] || exit 1
exec $real "\$@"
SHIM
  chmod 0755 "$FX_MAIN/fakebin/mv"
}

# The captain's own hand path in a manual-backend home: the backlog row is
# released straight through the backlog tool, without the per-task control
# lock bin/fm-captain-hold.sh takes for its own answer.
unhold_landing_row_directly() {
  (cd "$FX_MAIN" && tasks-axi unhold "$FX_LANDING") >/dev/null 2>&1
}

test_seed_binds_the_local_only_clone() {
  local binding parent_head child_head
  make_bound_fixture seed-binds

  parent_head=$(git -C "$FX_MAIN/projects/app" rev-parse HEAD)
  child_head=$(git -C "$FX_CLONE" rev-parse HEAD)
  assert_equals "$parent_head" "$child_head" \
    "the bound clone did not start from the primary's local default commit"
  assert_equals "" "$(git -C "$FX_CLONE" remote)" \
    "the bound clone carries a publication remote"
  assert_absent "$FX_CLONE/.git/objects/info/alternates" \
    "the bound clone borrows objects from the primary instead of owning them"
  assert_absent "$FX_CLONE/.no-mistakes" \
    "the bound local-only clone was initialized for no-mistakes"

  binding="$FX_CHILD/data/local-only-bindings/app.binding"
  assert_present "$binding" "seeding published no local-only binding"
  assert_equals fm-local-only-binding.v1 "$(record_field "$binding" schema)" \
    "the binding does not carry its versioned schema"
  assert_equals app "$(record_field "$binding" project)" \
    "the binding names the wrong project"
  assert_equals "$(cd "$FX_MAIN" && pwd -P)" "$(record_field "$binding" parent_home)" \
    "the binding names the wrong parent home"
  assert_equals "$(cd "$FX_MAIN/projects/app" && pwd -P)" \
    "$(record_field "$binding" parent_project)" \
    "the binding names the wrong parent clone"
  assert_equals "$parent_head" "$(record_field "$binding" seed_commit)" \
    "the binding does not pin the commit the copy was seeded from"
  pass "seeding a local-only project binds an independent child copy to its parent"
}

test_seed_refuses_an_unbound_or_published_local_only_clone() {
  local binding out err
  make_bound_fixture seed-rebind
  binding="$FX_CHILD/data/local-only-bindings/app.binding"
  out="$TMP_ROOT/seed-rebind.out"
  err="$TMP_ROOT/seed-rebind.err"

  FM_HOME="$FX_MAIN" "$SEED" localsub "$FX_CHILD" app >"$out" 2>"$err" \
    || fail "re-seeding an already bound local-only home failed"$'\n'"$(cat "$err")"

  mv "$binding" "$binding.saved"
  if FM_HOME="$FX_MAIN" "$SEED" localsub "$FX_CHILD" app >"$out" 2>"$err"; then
    fail "seeding accepted a preexisting local-only clone with no binding"
  fi
  assert_grep 'has no local-only binding' "$err" \
    "seeding did not explain the missing binding"
  mv "$binding.saved" "$binding"

  git -C "$FX_CLONE" remote add origin "$FX_MAIN/projects/app"
  if FM_HOME="$FX_MAIN" "$SEED" localsub "$FX_CHILD" app >"$out" 2>"$err"; then
    fail "seeding accepted a local-only clone that had gained a publication remote"
  fi
  assert_grep 'has origin' "$err" \
    "seeding did not explain the unexpected remote on the bound clone"
  git -C "$FX_CLONE" remote remove origin
  pass "local-only seeding is idempotent and refuses an unbound or published copy"
}

test_child_home_cannot_land_its_own_bound_clone() {
  local err status=0
  make_bound_fixture child-cannot-land
  commit_child_work 'child work'
  err="$TMP_ROOT/child-cannot-land.err"

  run_home "$FX_CHILD" "$MERGE" "$FX_TASK" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a child home landed work in its own bound copy"
  assert_grep 'is a bound local-only clone' "$err" \
    "the refusal did not name the bound copy"
  assert_grep "bin/fm-local-handoff.sh offer $FX_TASK" "$err" \
    "the refusal did not name the publication path that does work"
  pass "a bound local-only copy refuses to land its own work"
}

test_offer_pins_the_head_and_republishes_unchanged() {
  local out head moved err status=0
  make_bound_fixture offer-pins
  commit_child_work 'first change'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")

  out=$(run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK") \
    || fail "publishing the landing offer failed"
  assert_contains "$out" "offer=$FX_OFFER" "the offer did not report its own record"
  assert_contains "$out" "head=$head" "the offer did not pin the branch head"
  assert_equals "$head" "$(record_field "$FX_OFFER" head)" \
    "the published offer records a different head"
  assert_equals "fm/$FX_TASK" "$(record_field "$FX_OFFER" branch)" \
    "the published offer records a different branch"
  assert_equals 7 "$(record_field "$FX_OFFER" spawn_gen)" \
    "the published offer does not carry the task incarnation"
  assert_equals "$head refs/heads/fm/$FX_TASK" \
    "$(git -C "$FX_CLONE" bundle list-heads "$FX_OFFER.bundle")" \
    "the offer bundle does not hold exactly the offered head"

  out=$(run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK") \
    || fail "republishing an unchanged offer failed"
  assert_contains "$out" "unchanged=1" "an unchanged republication was not reported as such"

  # "unchanged" is a claim about the whole custody the offer names, not about
  # the head alone: a record that disagrees about any part of it is replaced.
  sed -i.bak 's#^parent_home=.*#parent_home=/nonexistent/other-home#' "$FX_OFFER"
  rm -f "$FX_OFFER.bak"
  out=$(run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK") \
    || fail "republishing an offer that named another parent home failed"
  assert_not_contains "$out" "unchanged=1" \
    "an offer naming a different parent home was reported as unchanged"
  assert_equals "$(cd "$FX_MAIN" && pwd -P)" "$(record_field "$FX_OFFER" parent_home)" \
    "republication did not restore the offer's real parent home"

  # The bundle carries the commit, so an offer without it is not unchanged
  # either; the parent would have nothing to import.
  rm -f "$FX_OFFER.bundle"
  out=$(run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK") \
    || fail "republishing an offer whose bundle had gone missing failed"
  assert_not_contains "$out" "unchanged=1" \
    "an offer whose bundle was gone was reported as unchanged"
  assert_present "$FX_OFFER.bundle" "republication did not restore the offer bundle"

  commit_child_work 'second change'
  moved=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  out=$(run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK") \
    || fail "publishing a moved head failed"
  assert_contains "$out" "head=$moved" "a moved head did not publish a new offer"
  assert_not_contains "$out" "unchanged=1" "a moved head was reported as unchanged"
  assert_equals "$moved refs/heads/fm/$FX_TASK" \
    "$(git -C "$FX_CLONE" bundle list-heads "$FX_OFFER.bundle")" \
    "the offer bundle still holds the superseded head"

  printf 'uncommitted\n' > "$FX_WT/work.txt"
  err="$TMP_ROOT/offer-dirty.err"
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "the offer accepted a dirty worktree"
  assert_grep 'uncommitted changes' "$err" "the refusal did not name the uncommitted work"
  pass "a landing offer pins one exact head and refuses uncommitted work"
}

test_delegated_landing_fast_forwards_and_publishes_a_receipt() {
  local head out receipt before after
  make_bound_fixture landing
  commit_child_work 'landed change'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (delegated landing)"; return 0; }
  approve_current_offer
  before=$(git -C "$FX_MAIN/projects/app" rev-parse HEAD)

  out=$(run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" 2>&1) \
    || fail "the delegated landing failed"$'\n'"$out"
  after=$(git -C "$FX_MAIN/projects/app" rev-parse HEAD)
  assert_equals "$head" "$after" "the primary's local default was not fast-forwarded to the offered head"
  assert_not_equals "$before" "$after" "the primary's local default did not move at all"
  assert_contains "$out" "landed $FX_TASK at $head into local main" \
    "the landing did not report the exact head it landed"
  assert_equals "" "$(git -C "$FX_MAIN/projects/app" for-each-ref refs/fm-local-handoff)" \
    "the landing left its private import ref behind"
  assert_equals "" "$(git -C "$FX_MAIN/projects/app" remote)" \
    "the landing added a remote to the primary clone"

  # The parent keeps its own record of what it landed, independent of anything
  # in the child home.
  assert_present "$FX_LANDING_RECORD" "the landing wrote no parent-owned landing record"
  assert_equals fm-local-landing.v1 "$(record_field "$FX_LANDING_RECORD" schema)" \
    "the landing record does not carry its versioned schema"
  assert_equals landed "$(record_field "$FX_LANDING_RECORD" state)" \
    "the landing record was not completed after the fast-forward"
  assert_equals "$head" "$(record_field "$FX_LANDING_RECORD" head)" \
    "the landing record pins a different head than the one that landed"

  receipt="$FX_CHILD/state/$FX_TASK.local-receipt"
  assert_present "$receipt" "the landing published no receipt in the child home"
  assert_contains "$out" "receipt=$receipt" "the landing did not report the receipt it wrote"
  assert_equals fm-local-receipt.v1 "$(record_field "$receipt" schema)" \
    "the receipt does not carry its versioned schema"
  assert_equals "$head" "$(record_field "$receipt" head)" "the receipt records a different head"
  assert_equals "$FX_TASK" "$(record_field "$receipt" task)" "the receipt names a different task"
  assert_equals 7 "$(record_field "$receipt" spawn_gen)" \
    "the receipt does not bind the task incarnation"
  assert_equals main "$(record_field "$receipt" default_branch)" \
    "the receipt does not name the branch the work landed on"
  assert_equals land-app "$(record_field "$receipt" landing_id)" \
    "the receipt does not name the parent record that authorized the landing"

  assert_equals "done" "$(landing_row_state)" \
    "the landing did not close its parent-owned landing row"

  out=$(run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" 2>&1) \
    || fail "cleanup refused a task whose genuine receipt was published"$'\n'"$out"
  assert_absent "$FX_CHILD/state/$FX_TASK.meta" "cleanup left the task record behind"
  pass "a pinned delegated landing fast-forwards the primary, receipts the child, and closes its row"
}

test_delegated_landing_refuses_an_unpinned_or_stale_approval() {
  local head err status
  make_bound_fixture landing-refusals
  commit_child_work 'offered change'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  err="$TMP_ROOT/landing-refusals.err"

  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" >/dev/null 2>"$err" || status=$?
  expect_code 2 "$status" "a landing ran without the approved commit"
  assert_grep 'needs both --offer and --expect-head' "$err" \
    "the refusal did not explain that approval is pinned to one commit"

  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" \
    --expect-head 0000000000000000000000000000000000000000 >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing accepted an approval pinned to another commit"
  assert_grep 'not the approved' "$err" "the refusal did not name the approval mismatch"

  # A valid offer and a matching --expect-head are not an approval. Without the
  # parent's own landing record there is nothing an approval was pinned to, so
  # the landing must refuse rather than treat the request itself as authority.
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing ran with no parent-owned landing record"
  assert_grep 'local-only-landings/land-app.landing' "$err" \
    "the refusal did not name the missing landing record"
  assert_grep 'bin/fm-local-handoff.sh request land-app' "$err" \
    "the refusal did not name the command that pins an approved offer"
  assert_equals "" "$(git -C "$FX_MAIN/projects/app" for-each-ref refs/fm-local-handoff)" \
    "a landing refused before its approval imported the offered commit anyway"

  # A parent-owned landing record is never a worker record, so an id that
  # already names a task in this home refuses rather than borrowing it.
  fm_write_meta "$FX_MAIN/state/land-app.meta" "kind=ship" "mode=local-only"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing took over an existing worker record"
  assert_grep 'has a worker record at' "$err" "the refusal did not name the record collision"
  rm -f "$FX_MAIN/state/land-app.meta"

  # The child moved on after the approval: the pinned head is no longer what
  # the branch holds, so the landing must refuse instead of landing either one.
  commit_child_work 'work after the approval'
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing accepted an offer whose branch had moved"
  assert_grep "no longer points at the offered head" "$err" \
    "the refusal did not name the moved branch head"
  git -C "$FX_WT" reset -q --hard "$head"

  # A respawned child task is a different incarnation of the same id, and the
  # approval named the old one.
  sed -i.bak 's/^spawn_gen=7$/spawn_gen=8/' "$FX_CHILD/state/$FX_TASK.meta"
  rm -f "$FX_CHILD/state/$FX_TASK.meta.bak"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing accepted an offer from a superseded incarnation"
  assert_grep 'is now incarnation 8, not the offered 7' "$err" \
    "the refusal did not name the changed incarnation"

  assert_equals "$(git -C "$FX_MAIN/projects/app" rev-parse HEAD)" \
    "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "a refused landing moved the primary's default branch"
  pass "a delegated landing refuses an unpinned, colliding, moved, or superseded approval"
}

# The pin exists so that one recorded release covers exactly one commit. A
# child that keeps working after the captain answered must not inherit it.
test_a_released_approval_covers_only_the_head_it_pinned() {
  local first second err status
  make_bound_fixture reused-approval
  commit_child_work 'first approved change'
  first=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (reused approval)"; return 0; }
  approve_current_offer
  err="$TMP_ROOT/reused-approval.err"

  commit_child_work 'work after the captain answered'
  second=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "republishing the moved head failed"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$second" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a released approval landed a head it never named"
  assert_grep "pins head $first" "$err" \
    "the refusal did not name the commit the approval was pinned to"
  assert_not_equals "$second" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "a stale approval still moved the primary's default branch"
  assert_absent "$FX_CHILD/state/$FX_TASK.local-receipt" \
    "a refused landing published a receipt"

  # The recorded way forward is a second landing row with its own pin, because
  # the first record is the durable approval of the first head and is never
  # rewritten to name another one.
  status=0
  run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a pinned approval was repointed at a later head"
  assert_grep 'a published pin is never replaced' "$err" \
    "the refusal did not say the pinned approval stands"
  assert_equals "$first" "$(record_field "$FX_LANDING_RECORD" head)" \
    "a refused re-pin changed the record the captain answered"

  prepare_landing_row land-app-2 || fail "filing a second landing row failed"
  approve_current_offer
  run_home "$FX_MAIN" "$MERGE" land-app-2 --offer "$FX_OFFER" --expect-head "$second" \
    >/dev/null 2>"$err" || fail "a freshly approved head failed to land"$'\n'"$(cat "$err")"
  assert_equals "$second" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "the freshly approved head did not land"
  pass "a released approval lands only the exact head it was pinned to"
}

# Pinning is not approving: it binds a pending captain call to one commit, so
# it is accepted only while that call is genuinely open.
test_pinning_an_offer_needs_an_open_captain_call() {
  local err status landing
  make_bound_fixture request-gate
  commit_child_work 'change awaiting approval'
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  err="$TMP_ROOT/request-gate.err"
  landing="$FX_MAIN/data/local-only-landings/land-app.landing"

  status=0
  run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "an offer was pinned to a landing row this home does not have"
  assert_grep 'no landing row land-app' "$err" "the refusal did not name the missing row"
  assert_absent "$landing" "a refused pin wrote a landing record anyway"

  if prepare_landing_row land-app; then
    release_landing_row || fail "releasing the landing row failed"
    status=0
    run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER" \
      >/dev/null 2>"$err" || status=$?
    expect_code 1 "$status" "an offer was pinned to a call the captain had already answered"
    assert_grep 'is not held for the captain' "$err" \
      "the refusal did not name the closed captain call"
    assert_absent "$landing" "a refused pin wrote a landing record anyway"
  else
    echo "skip: tasks-axi cannot host the landing row (released-row pin)"
  fi
  pass "an offer can only be pinned while its captain call is still open"
}

# A refused landing must leave the primary clone exactly as it found it,
# including the private ref the bundle import created.
test_a_refused_landing_leaves_no_imported_ref() {
  local head err status
  make_bound_fixture non-fast-forward
  commit_child_work 'offered change'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (non-fast-forward)"; return 0; }
  approve_current_offer
  err="$TMP_ROOT/non-fast-forward.err"

  # The primary moved on independently, so the offered head is no longer a
  # fast-forward of its default branch.
  printf 'primary side\n' > "$FX_MAIN/projects/app/primary.txt"
  git -C "$FX_MAIN/projects/app" add primary.txt
  git -C "$FX_MAIN/projects/app" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'primary side'

  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a diverged offer was landed anyway"
  assert_grep 'not a fast-forward' "$err" "the refusal did not name the divergence"
  assert_equals "" "$(git -C "$FX_MAIN/projects/app" for-each-ref refs/fm-local-handoff)" \
    "a refused landing left the offered commit in a private import ref"
  assert_equals pinned "$(record_field "$FX_LANDING_RECORD" state)" \
    "a refused landing recorded itself as landed"
  assert_absent "$FX_CHILD/state/$FX_TASK.local-receipt" \
    "a refused landing published a receipt"
  pass "a refused landing imports nothing durable into the primary clone"
}

# Local-only custody is the reason this path exists, so a project that is no
# longer registered local-only has left it.
test_landing_refuses_a_project_moved_off_local_only() {
  local head err status before
  make_bound_fixture mode-changed
  commit_child_work 'offered change'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (changed delivery mode)"; return 0; }
  approve_current_offer
  err="$TMP_ROOT/mode-changed.err"
  before=$(git -C "$FX_MAIN/projects/app" rev-parse main)

  printf '%s\n' '- app [no-mistakes] - app project (added 2026-06-22)' \
    > "$FX_MAIN/data/projects.md"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing ran for a project that had left local-only custody"
  assert_grep 'not local-only' "$err" "the refusal did not name the changed delivery route"
  assert_equals "$before" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "a refused landing moved the primary's default branch"
  assert_equals "" "$(git -C "$FX_MAIN/projects/app" for-each-ref refs/fm-local-handoff)" \
    "a refused landing left the offered commit in a private import ref"
  assert_absent "$FX_CHILD/state/$FX_TASK.local-receipt" \
    "a refused landing published a receipt"
  pass "a landing refuses a project that is no longer registered local-only"
}

test_receipt_recovery_is_idempotent_and_proves_the_landing() {
  local head receipt out err status=0 backlog_before
  make_bound_fixture receipt-recovery
  commit_child_work 'recovered change'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  receipt="$FX_CHILD/state/$FX_TASK.local-receipt"
  err="$TMP_ROOT/receipt-recovery.err"
  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (receipt recovery)"; return 0; }
  approve_current_offer

  run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER" --landing land-app \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "receipt recovery wrote a receipt for work that never landed"
  assert_grep 'is not present in' "$err" \
    "the refusal did not name the commit the primary never received"
  assert_absent "$receipt" "a refused recovery left a receipt behind"

  # Having the commit is not having landed it: an imported but unmerged head
  # must still refuse, because containment in the default branch is the proof.
  git -C "$FX_MAIN/projects/app" fetch --no-tags --quiet "$FX_OFFER.bundle" \
    "refs/heads/fm/$FX_TASK:refs/fm-local-handoff-test/imported"
  status=0
  run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER" --landing land-app \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "receipt recovery accepted a commit that was merely present"
  assert_grep 'is not contained in main' "$err" \
    "the refusal did not name the missing containment proof"
  assert_absent "$receipt" "a refused recovery left a receipt behind"
  assert_equals pinned "$(record_field "$FX_LANDING_RECORD" state)" \
    "a refused recovery recorded a landing that never happened"
  git -C "$FX_MAIN/projects/app" update-ref -d refs/fm-local-handoff-test/imported

  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" >/dev/null \
    || fail "the delegated landing failed"
  # A landing whose receipt publication was interrupted leaves exactly this.
  rm -f "$receipt"
  out=$(run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER" --landing land-app) \
    || fail "receipt recovery failed after a genuine landing"
  assert_contains "$out" "receipt=$receipt" "recovery did not report the receipt it wrote"
  assert_equals "$head" "$(record_field "$receipt" head)" "the recovered receipt names another head"

  assert_equals "done" "$(landing_row_state)" "recovery reopened or lost the closed landing row"
  backlog_before=$(cat "$FX_MAIN/data/backlog.md" "$FX_MAIN/data/done-archive.md" 2>/dev/null)
  out=$(run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER" --landing land-app) \
    || fail "repeating receipt recovery failed"
  assert_contains "$out" "unchanged=1" "a repeated recovery was not reported as unchanged"
  assert_equals "$backlog_before" \
    "$(cat "$FX_MAIN/data/backlog.md" "$FX_MAIN/data/done-archive.md" 2>/dev/null)" \
    "a repeated recovery changed the backlog again"
  assert_equals "$head" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "a repeated recovery landed the work a second time"
  assert_equals landed "$(record_field "$FX_LANDING_RECORD" state)" \
    "recovery did not complete the parent's own landing record"
  pass "receipt recovery proves the landing from the repository and repeats safely"
}

# A landing that moved the primary's default branch but could not publish its
# receipt is landed yet unacknowledged, so its row stays open until recovery
# finishes the receipt, and recovery never lands a second time.
test_a_failed_receipt_keeps_the_landing_row_open_until_recovery() {
  local head err status out landed_commits receipt
  make_bound_fixture receipt-failure
  commit_child_work 'change whose receipt fails'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (failed receipt)"; return 0; }
  approve_current_offer
  receipt="$FX_CHILD/state/$FX_TASK.local-receipt"
  err="$TMP_ROOT/receipt-failure.err"

  install_receipt_failure_shim
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing whose receipt failed reported success"
  assert_grep 'landing receipt could not be published' "$err" \
    "the failure did not name the unpublished receipt"
  assert_grep "fm-local-handoff.sh receipt $FX_OFFER --landing land-app" "$err" \
    "the failure did not name the recovery command"
  assert_equals "$head" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "the fast-forward itself did not happen"
  assert_absent "$receipt" "a failed publication left a receipt behind"
  assert_equals landed "$(record_field "$FX_LANDING_RECORD" state)" \
    "the landing record did not record the landing that happened"
  assert_equals in_flight "$(landing_row_state)" \
    "the landing row did not stay open while its receipt was missing"
  landed_commits=$(git -C "$FX_MAIN/projects/app" rev-list --count main)
  rm -f "$FX_MAIN/fakebin/mv"

  out=$(run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER" --landing land-app) \
    || fail "receipt recovery failed after a landed but unacknowledged landing"
  assert_contains "$out" "receipt=$receipt" "recovery did not report the receipt it wrote"
  assert_equals "$head" "$(record_field "$receipt" head)" "the recovered receipt names another head"
  assert_equals "done" "$(landing_row_state)" "recovery did not close the landing row"
  assert_equals "$landed_commits" "$(git -C "$FX_MAIN/projects/app" rev-list --count main)" \
    "recovery added history to the primary's default branch"

  out=$(run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER" --landing land-app) \
    || fail "repeating receipt recovery failed"
  assert_contains "$out" "unchanged=1" "a repeated recovery was not reported as unchanged"
  assert_equals "done" "$(landing_row_state)" "a repeated recovery changed the closed landing row"
  pass "a failed receipt keeps the landing row open until recovery closes it without relanding"
}

test_teardown_requires_the_parent_receipt() {
  local head err status out
  make_bound_fixture teardown-gate
  commit_child_work 'work to land'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  err="$TMP_ROOT/teardown-gate.err"

  status=0
  run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "cleanup removed a bound local-only task that had offered nothing"
  assert_grep 'has published no landing offer' "$err" \
    "the refusal did not name the missing offer"

  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  status=0
  run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "cleanup removed work the parent had not landed"
  assert_grep "no durable proof that $head reached the parent's default branch" "$err" \
    "the refusal did not name the missing landing proof"

  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (teardown gate)"; return 0; }
  approve_current_offer
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" >/dev/null 2>&1 \
    || fail "the delegated landing failed"

  # Committing past the offer means the receipt proves something older than
  # what this copy now holds, so cleanup must refuse until the new head lands.
  commit_child_work 'work after the landing'
  status=0
  run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "cleanup discarded commits made after the landed head"
  assert_grep "has committed work at" "$err" \
    "the refusal did not name the work committed past the offer"
  git -C "$FX_WT" reset -q --hard "$head"

  out=$(run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" 2>&1) \
    || fail "cleanup refused a task the parent had genuinely landed"$'\n'"$out"
  assert_absent "$FX_CHILD/state/$FX_TASK.meta" "cleanup left the task record behind"
  pass "cleanup of a bound local-only task needs the parent's durable receipt"
}

# A receipt is evidence, never authority. Which clone the work had to reach is
# the child's own binding's fact, so a receipt that names some other repository
# - including this copy, where a child-local merge really did happen - proves
# nothing and must not open the cleanup gate.
test_a_substituted_parent_clone_proves_nothing() {
  local head err status
  make_bound_fixture forged-parent
  commit_child_work 'work merged only here'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  git -C "$FX_CLONE" merge --ff-only "fm/$FX_TASK" >/dev/null \
    || fail "could not merge the child's branch inside its own copy"
  assert_equals "$head" "$(git -C "$FX_CLONE" rev-parse main)" \
    "the child-local merge did not happen, so this case proves nothing"
  err="$TMP_ROOT/forged-parent.err"

  forge_receipt "$FX_CLONE"
  status=0
  run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "cleanup accepted a receipt naming the child's own copy"
  assert_grep 'as the primary clone' "$err" \
    "the refusal did not name the substituted clone"
  assert_present "$FX_CHILD/state/$FX_TASK.meta" "a refused cleanup removed the task record"


  # Naming the real parent clone is not enough either: the parent's own
  # landing record is what the child cannot write for itself.
  forge_receipt "$(cd "$FX_MAIN/projects/app" && pwd -P)"
  status=0
  run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "cleanup accepted a receipt the parent never backed with a record"
  assert_grep 'local-only-landings/land-app.landing' "$err" \
    "the refusal did not name the missing parent-owned landing record"
  assert_present "$FX_CHILD/state/$FX_TASK.meta" "a refused cleanup removed the task record"
  pass "a receipt naming another clone, or no parent record, opens nothing"
}

# A worktree that is already gone answers none of the git questions cleanup
# normally asks, but it is not evidence that the parent landed the work.
test_the_receipt_gate_survives_a_missing_worktree() {
  local head err status out
  make_bound_fixture absent-worktree
  commit_child_work 'work to land'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  err="$TMP_ROOT/absent-worktree.err"

  rm -rf "$FX_WT"
  status=0
  run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "cleanup reported success for unlanded work whose worktree was gone"
  assert_grep "no durable proof that $head reached the parent's default branch" "$err" \
    "the refusal did not name the missing landing proof"
  assert_present "$FX_CHILD/state/$FX_TASK.meta" "a refused cleanup removed the task record"

  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (absent worktree)"; return 0; }
  approve_current_offer
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" >/dev/null 2>&1 \
    || fail "the delegated landing failed"
  out=$(run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" 2>&1) \
    || fail "cleanup refused landed work whose worktree was already gone"$'\n'"$out"
  assert_absent "$FX_CHILD/state/$FX_TASK.meta" "cleanup left the task record behind"

  # The parent's evidence of what it landed outlives the child task entirely.
  assert_present "$FX_LANDING_RECORD" "retiring the child task removed the parent's landing record"
  assert_equals landed "$(record_field "$FX_LANDING_RECORD" state)" \
    "the retained landing record no longer records the landing"
  assert_equals "$head" "$(record_field "$FX_LANDING_RECORD" head)" \
    "the retained landing record no longer names the landed head"
  pass "an absent worktree still faces the receipt gate, and the parent's record outlives the child"
}

# One damaged record must never be read as a weaker version of a good one.
# The landing is the strictest consumer, so it drives the offer cases; the
# cleanup gate drives the receipt case.
test_damaged_records_fail_closed() {
  local head saved err status default_before receipt
  make_bound_fixture damaged-records
  commit_child_work 'offered change'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  saved="$TMP_ROOT/damaged-records.offer"
  cp "$FX_OFFER" "$saved"
  err="$TMP_ROOT/damaged-records.err"
  default_before=$(git -C "$FX_MAIN/projects/app" rev-parse main)

  printf 'extra=1\n' >> "$FX_OFFER"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing accepted an offer carrying an unknown key"
  assert_grep 'unknown key extra' "$err" "the refusal did not name the unknown key"

  cp "$saved" "$FX_OFFER"
  printf 'head=%s\n' "$head" >> "$FX_OFFER"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing accepted an offer that repeats a key"
  assert_grep 'repeats key head' "$err" "the refusal did not name the repeated key"

  cp "$saved" "$FX_OFFER"
  printf 'x\000y\n' >> "$FX_OFFER"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing accepted an offer holding NUL bytes"
  assert_grep 'NUL bytes' "$err" "the refusal did not name the NUL bytes"

  rm -f "$FX_OFFER"
  ln -s "$saved" "$FX_OFFER"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing followed a symlinked offer"
  assert_grep 'not an ordinary file' "$err" "the refusal did not name the symlinked record"
  rm -f "$FX_OFFER"
  cp "$saved" "$FX_OFFER"

  assert_equals "$default_before" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "a refused landing moved the primary's default branch"

  if prepare_landing_row land-app; then
    approve_current_offer
    # A landing record damaged after the pin is no weaker an approval either.
    cp "$FX_LANDING_RECORD" "$TMP_ROOT/damaged-records.landing"
    printf 'extra=1\n' >> "$FX_LANDING_RECORD"
    status=0
    run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
      >/dev/null 2>"$err" || status=$?
    expect_code 1 "$status" "a landing accepted a landing record carrying an unknown key"
    assert_grep 'unknown key extra' "$err" \
      "the refusal did not name the unknown key in the landing record"

    # Nor is a damaged approval something a new pin may write over.
    status=0
    run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER" \
      >/dev/null 2>"$err" || status=$?
    expect_code 1 "$status" "a damaged approval was replaced by a fresh pin"
    assert_grep 'unknown key extra' "$err" \
      "the refusal did not name the damaged record it refused to replace"
    cp "$TMP_ROOT/damaged-records.landing" "$FX_LANDING_RECORD"

    run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" >/dev/null 2>&1 \
      || fail "the delegated landing failed after the damaged records were restored"
    receipt="$FX_CHILD/state/$FX_TASK.local-receipt"
    sed -i.bak "s/^head=.*/head=$default_before/" "$receipt"
    rm -f "$receipt.bak"
    status=0
    run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" >/dev/null 2>"$err" || status=$?
    expect_code 1 "$status" "cleanup accepted a receipt edited to name another commit"
    assert_grep "but the offer says $head" "$err" \
      "the refusal did not name the receipt's disagreement with the offer"
    assert_present "$FX_CHILD/state/$FX_TASK.meta" "a refused cleanup removed the task record"
  else
    echo "skip: tasks-axi cannot host the landing row (damaged landing record and receipt)"
  fi
  pass "damaged offer, landing, and receipt records refuse instead of landing or proving anything"
}

# The delegated landing's authority is the parent-owned landing row, read
# through the same captain-hold check every local landing runs.
test_a_held_landing_row_blocks_the_delegated_landing() {
  local head out err status
  make_bound_fixture held-landing
  commit_child_work 'change awaiting approval'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (held landing row)"; return 0; }

  out=$(run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER") \
    || fail "pinning an offer to the held landing row failed"
  assert_contains "$out" "state=pinned" "the pin did not report the record it wrote"
  assert_contains "$out" "head=$head" "the pin did not report the commit it bound"
  assert_equals pinned "$(record_field "$FX_LANDING_RECORD" state)" \
    "the landing record was not left pinned and unlanded"
  assert_equals "$head" "$(record_field "$FX_LANDING_RECORD" head)" \
    "the landing record pinned another commit"

  err="$TMP_ROOT/held-landing.err"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing ran while its own record was still held for the captain"
  assert_grep 'still held for the captain' "$err" "the refusal did not name the open captain call"
  assert_absent "$FX_CHILD/state/$FX_TASK.local-receipt" \
    "a refused landing published a receipt"
  assert_equals pinned "$(record_field "$FX_LANDING_RECORD" state)" \
    "a refused landing recorded itself as landed"
  assert_not_equals "$head" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "a held landing still moved the primary's default branch"
  pass "a landing record still held for the captain blocks the delegated landing"
}

# A published pin is the captain's approval of one exact head, so two requests
# that overlap on the same landing row cannot trade places: the one that
# publishes first owns the row, and the other learns that rather than writing
# over it.
test_overlapping_requests_never_replace_a_pin() {
  local first second err_a err_b out_b pin_a pin_b status_b
  make_bound_fixture overlapping-pins
  commit_child_work 'first offered change'
  first=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (overlapping pins)"; return 0; }
  err_a="$TMP_ROOT/overlapping-pins.a.err"
  err_b="$TMP_ROOT/overlapping-pins.b.err"
  out_b="$TMP_ROOT/overlapping-pins.b.out"

  install_pin_pause_shim overlapping-pins before
  run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER" \
    >/dev/null 2>"$err_a" &
  pin_a=$!
  wait_for_path "$FX_RACE_AT" "the first request reaching its publication"

  # The child moves on while that request is frozen, so the second request
  # carries a genuinely different head into the same window.
  commit_child_work 'change offered while the first pin was in flight'
  second=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  assert_not_equals "$first" "$second" "the second offer did not move the head"
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "republishing the moved head failed"
  run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER" \
    >"$out_b" 2>"$err_b" &
  pin_b=$!
  kill -0 "$pin_b" 2>/dev/null \
    || fail "the second request did not overlap the first one's publication"

  : > "$FX_RACE_GO"
  wait "$pin_a" || fail "the frozen request failed"$'\n'"$(cat "$err_a")"
  status_b=0
  wait "$pin_b" || status_b=$?
  expect_code 1 "$status_b" "an overlapping request replaced a published pin"
  assert_grep 'a published pin is never replaced' "$err_b" \
    "the losing request did not report the pin that already owns the row"
  assert_no_grep "$second" "$FX_LANDING_RECORD" \
    "the losing request wrote its own head into the published pin"
  assert_equals "$first" "$(record_field "$FX_LANDING_RECORD" head)" \
    "the published pin lost the head it was written for"
  assert_equals pinned "$(record_field "$FX_LANDING_RECORD" state)" \
    "the published pin did not survive the overlapping request"
  pass "overlapping requests cannot replace a published pin"
}

# The window the review reproduced: a captain answer recorded between a
# request's own check and its publication. The request holds the landing's
# control lock across both, which is the same lock the answer takes, so the
# answer cannot land inside that window at all.
test_a_captains_answer_waits_for_a_pin_in_flight() {
  local head err out pin released rel started baseline tries publisher owner
  make_bound_fixture pin-before-answer
  commit_child_work 'change awaiting approval'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  prepare_landing_row land-baseline \
    || { echo "skip: tasks-axi cannot host the landing row (answer during pin)"; return 0; }
  err="$TMP_ROOT/pin-before-answer.err"
  released="$TMP_ROOT/pin-before-answer.answered"

  # What an uncontended answer costs on this host, measured with the same
  # command on its own row. An answer that has simply not finished yet proves
  # nothing, so the window below stays open for longer than that measurement
  # rather than for a constant a slow host can outlast on its own.
  started=$SECONDS
  release_landing_row || fail "the uncontended baseline answer failed"
  baseline=$((SECONDS - started))
  prepare_landing_row land-app || fail "filing the pinned landing row failed"

  install_pin_pause_shim pin-before-answer before
  run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER" \
    >/dev/null 2>"$err" &
  pin=$!
  wait_for_path "$FX_RACE_AT" "the request reaching its publication"
  publisher=$(cat "$FX_RACE_AT" 2>/dev/null || true)

  # The captain answers through the ordinary wrapper while the pin is frozen.
  ( release_landing_row; : > "$released" ) &
  rel=$!

  # What that answer is waiting for, stated positively rather than inferred
  # from an absence: the landing's own control lock is held by the very
  # process that is publishing the pin. A request that took no such lock
  # leaves this lock unheld or owned by the answer itself, so this assertion,
  # not a timer, is what fails when the serialization is removed.
  owner=$(cat "$FX_MAIN/state/.control-land-app.lock/pid" 2>/dev/null || true)
  lock_holder_is_the_publisher "$owner" "$publisher" \
    || fail "the landing's control lock was held by '$owner', not by the request publishing the pin"

  # The same conclusion measured independently: the answer stays unrecorded
  # for longer than an uncontended one costs on this host.
  tries=$(( (baseline + 1) * 20 ))
  while [ "$tries" -gt 0 ]; do
    assert_absent "$released" \
      "the captain's answer was recorded while a pin for that row was still in flight"
    sleep 0.05
    tries=$((tries - 1))
  done

  # The boundary itself: the answer is still alive, its row still reads held,
  # and its completion is still absent at the instant the pin is let go.
  kill -0 "$rel" 2>/dev/null \
    || fail "the captain's answer was no longer running, so this window proved nothing"
  run_home "$FX_MAIN" "$ROOT/bin/fm-captain-hold.sh" open land-app >/dev/null 2>&1 \
    || fail "the landing row stopped reading as held while its own pin was in flight"
  assert_absent "$released" \
    "the captain's answer completed before the pin it overlapped was published"
  : > "$FX_RACE_GO"
  wait "$pin" || fail "the frozen request failed"$'\n'"$(cat "$err")"
  wait "$rel" || fail "the captain's answer never completed"
  wait_for_path "$released" "the captain's answer completing after the pin"
  if run_home "$FX_MAIN" "$ROOT/bin/fm-captain-hold.sh" open land-app >/dev/null 2>&1; then
    fail "the answer that completed after the pin never took effect on its row"
  fi
  assert_equals "$head" "$(record_field "$FX_LANDING_RECORD" head)" \
    "the pin did not record the head it was written for"
  assert_equals pinned "$(record_field "$FX_LANDING_RECORD" state)" \
    "the pin did not survive the answer that followed it"

  # Re-running the same request is the interrupted-request recovery path: the
  # identity is unchanged, so it repeats the record rather than refusing.
  out=$(run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER") \
    || fail "re-running the identical request refused its own record"
  assert_contains "$out" "unchanged=1" "the repeated request was not reported as unchanged"
  assert_contains "$out" "head=$head" "the repeated request reported another head"

  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || fail "the approved head failed to land"$'\n'"$(cat "$err")"
  assert_equals "$head" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "the approved head did not reach the primary's default branch"
  pass "a captain's answer cannot be recorded inside a pin's publication window"
}

# An answer recorded outside that lock, straight through the backlog tool, is
# still possible. The request re-reads the row after publishing, withdraws its
# own record byte for byte, and an overlapping landing waits for that withdraw
# rather than consuming a pin no live answer covers.
test_a_pin_is_withdrawn_when_its_row_is_released_underneath_it() {
  local head err land_err pin land status land_status
  make_bound_fixture pin-overtaken
  commit_child_work 'change awaiting approval'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  prepare_landing_row land-app \
    || { echo "skip: tasks-axi cannot host the landing row (overtaken pin)"; return 0; }
  err="$TMP_ROOT/pin-overtaken.err"
  land_err="$TMP_ROOT/pin-overtaken.land.err"

  install_pin_pause_shim pin-overtaken after
  run_home "$FX_MAIN" "$HANDOFF" request land-app --offer "$FX_OFFER" \
    >/dev/null 2>"$err" &
  pin=$!
  wait_for_path "$FX_RACE_AT" "the request publishing its record"
  assert_present "$FX_LANDING_RECORD" "the frozen request published no record to withdraw"
  unhold_landing_row_directly || fail "releasing the row outside the wrapper failed"

  # A landing started inside the same window must not consume that record.
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$land_err" &
  land=$!
  : > "$FX_RACE_GO"
  status=0
  wait "$pin" || status=$?
  expect_code 1 "$status" "a pin survived the release that overtook it"
  assert_grep 'stopped being held while this offer was being pinned' "$err" \
    "the refusal did not name the answer that overtook the pin"
  assert_absent "$FX_LANDING_RECORD" "the overtaken pin was left behind as an approval"

  land_status=0
  wait "$land" || land_status=$?
  expect_code 1 "$land_status" "a landing consumed a pin that was being withdrawn"
  assert_grep 'record is missing or not an ordinary file' "$land_err" \
    "the landing did not refuse for the withdrawn record"
  assert_absent "$FX_CHILD/state/$FX_TASK.local-receipt" \
    "a refused landing published a receipt"
  assert_not_equals "$head" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "an overtaken pin still moved the primary's default branch"
  pass "a pin whose row is released underneath it is withdrawn, not inherited"
}

test_seed_binds_the_local_only_clone
test_seed_refuses_an_unbound_or_published_local_only_clone
test_child_home_cannot_land_its_own_bound_clone
test_offer_pins_the_head_and_republishes_unchanged
test_delegated_landing_fast_forwards_and_publishes_a_receipt
test_delegated_landing_refuses_an_unpinned_or_stale_approval
test_a_released_approval_covers_only_the_head_it_pinned
test_pinning_an_offer_needs_an_open_captain_call
test_a_refused_landing_leaves_no_imported_ref
test_landing_refuses_a_project_moved_off_local_only
test_receipt_recovery_is_idempotent_and_proves_the_landing
test_a_failed_receipt_keeps_the_landing_row_open_until_recovery
test_teardown_requires_the_parent_receipt
test_a_substituted_parent_clone_proves_nothing
test_the_receipt_gate_survives_a_missing_worktree
test_damaged_records_fail_closed
test_a_held_landing_row_blocks_the_delegated_landing
test_overlapping_requests_never_replace_a_pin
test_a_captains_answer_waits_for_a_pin_in_flight
test_a_pin_is_withdrawn_when_its_row_is_released_underneath_it
