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

  out=$(run_home "$FX_MAIN" "$HANDOFF" verify-receipt "$FX_CHILD" "$FX_TASK") \
    || fail "verifying a genuine receipt failed"
  assert_contains "$out" "landed=$head" "verification did not report the landed head"
  pass "a pinned delegated landing fast-forwards the primary and receipts the child"
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

test_receipt_recovery_is_idempotent_and_proves_the_landing() {
  local head receipt out err status=0
  make_bound_fixture receipt-recovery
  commit_child_work 'recovered change'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"
  receipt="$FX_CHILD/state/$FX_TASK.local-receipt"
  err="$TMP_ROOT/receipt-recovery.err"

  run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "receipt recovery wrote a receipt for work that never landed"
  assert_grep 'is not present in' "$err" \
    "the refusal did not name the commit the primary never received"
  assert_absent "$receipt" "a refused recovery left a receipt behind"

  # Having the commit is not having landed it: an imported but unmerged head
  # must still refuse, because containment in the default branch is the proof.
  git -C "$FX_MAIN/projects/app" fetch --no-tags --quiet "$FX_OFFER.bundle" \
    "refs/heads/fm/$FX_TASK:refs/fm-local-handoff-test/imported"
  status=0
  run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "receipt recovery accepted a commit that was merely present"
  assert_grep 'is not contained in main' "$err" \
    "the refusal did not name the missing containment proof"
  assert_absent "$receipt" "a refused recovery left a receipt behind"
  git -C "$FX_MAIN/projects/app" update-ref -d refs/fm-local-handoff-test/imported

  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" >/dev/null \
    || fail "the delegated landing failed"
  # A landing whose receipt publication was interrupted leaves exactly this.
  rm -f "$receipt"
  out=$(run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER") \
    || fail "receipt recovery failed after a genuine landing"
  assert_contains "$out" "receipt=$receipt" "recovery did not report the receipt it wrote"
  assert_equals "$head" "$(record_field "$receipt" head)" "the recovered receipt names another head"

  out=$(run_home "$FX_MAIN" "$HANDOFF" receipt "$FX_OFFER") \
    || fail "repeating receipt recovery failed"
  assert_contains "$out" "unchanged=1" "a repeated recovery was not reported as unchanged"
  assert_equals "$head" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "a repeated recovery landed the work a second time"
  pass "receipt recovery proves the landing from the repository and repeats safely"
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

# One damaged record must never be read as a weaker version of a good one.
# The landing is the strictest consumer, so it drives the offer cases; the
# read-only verification drives the receipt case.
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

  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" >/dev/null 2>&1 \
    || fail "the delegated landing failed after the damaged offers were restored"
  receipt="$FX_CHILD/state/$FX_TASK.local-receipt"
  sed -i.bak "s/^head=.*/head=$default_before/" "$receipt"
  rm -f "$receipt.bak"
  status=0
  run_home "$FX_MAIN" "$HANDOFF" verify-receipt "$FX_CHILD" "$FX_TASK" >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "verification accepted a receipt edited to name another commit"
  assert_grep "but the offer says $head" "$err" \
    "the refusal did not name the receipt's disagreement with the offer"
  pass "damaged offer and receipt records refuse instead of landing or proving anything"
}

# The delegated landing's authority is the parent-owned landing row, read
# through the same captain-hold check every local landing runs.
test_a_held_landing_row_blocks_the_delegated_landing() {
  local head err status
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (held landing row)"; return 0; }
  make_bound_fixture held-landing
  commit_child_work 'change awaiting approval'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null \
    || fail "publishing the landing offer failed"

  cp "$ROOT/.tasks.toml" "$FX_MAIN/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$FX_MAIN/data/backlog.md"
  (cd "$FX_MAIN" && tasks-axi add land-app "Land the child's offered work" --kind ship --start) \
    >/dev/null || { echo "skip: this tasks-axi cannot host the landing row"; return 0; }
  PATH="$FX_MAIN/fakebin:$PATH" FM_HOME="$FX_MAIN" FM_STATE_OVERRIDE="$FX_MAIN/state" \
    FM_DATA_OVERRIDE="$FX_MAIN/data" FM_CONFIG_OVERRIDE="$FX_MAIN/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold land-app --reason "captain approval for the child landing" \
    >/dev/null || { echo "skip: this tasks-axi cannot hold the landing row"; return 0; }

  err="$TMP_ROOT/held-landing.err"
  status=0
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" \
    >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a landing ran while its own record was still held for the captain"
  assert_grep 'still held for the captain' "$err" "the refusal did not name the open captain call"
  assert_absent "$FX_CHILD/state/$FX_TASK.local-receipt" \
    "a refused landing published a receipt"
  assert_not_equals "$head" "$(git -C "$FX_MAIN/projects/app" rev-parse main)" \
    "a held landing still moved the primary's default branch"
  pass "a landing record still held for the captain blocks the delegated landing"
}

test_seed_binds_the_local_only_clone
test_seed_refuses_an_unbound_or_published_local_only_clone
test_child_home_cannot_land_its_own_bound_clone
test_offer_pins_the_head_and_republishes_unchanged
test_delegated_landing_fast_forwards_and_publishes_a_receipt
test_delegated_landing_refuses_an_unpinned_or_stale_approval
test_receipt_recovery_is_idempotent_and_proves_the_landing
test_teardown_requires_the_parent_receipt
test_damaged_records_fail_closed
test_a_held_landing_row_blocks_the_delegated_landing
