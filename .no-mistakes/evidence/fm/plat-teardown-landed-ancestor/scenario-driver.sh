#!/usr/bin/env bash
# Driver: source the fixture helpers from tests/fm-local-handoff.test.sh (without
# its case list), then drive the real bin/ scripts in disposable homes.
set -u
cd "$1"
src=$(mktemp /tmp/fm-tdrv/helpers.XXXXXX.sh)
sed -n "1,1665p" tests/fm-local-handoff.test.sh | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$PWD/tests#" > "$src"
# shellcheck disable=SC1090
. "$src"
shift
say() { printf '\n=== %s\n' "$*"; }

# Mirror of the reported tf-sell-now landing: copy stays clean & detached at its
# launch commit, builder commits on fm/tf-sell-now in the bound project clone.
scenario_reported_shape() {
  local launch head scratch err out status
  make_bound_fixture reported tf-sell-now
  launch=$(git -C "$FX_WT" rev-parse HEAD)
  git -C "$FX_WT" checkout -q --detach "$launch"
  scratch="$TMP_ROOT/reported-builder"
  git -C "$FX_CLONE" worktree add --quiet "$scratch" "fm/$FX_TASK"
  printf 'sell now\n' > "$scratch/sell.txt"
  git -C "$scratch" add sell.txt
  git -C "$scratch" -c user.name=B -c user.email=b@example.invalid commit -qm 'builder work on the branch'
  printf 'sell now 2\n' >> "$scratch/sell.txt"
  git -C "$scratch" -c user.name=B -c user.email=b@example.invalid commit -qam 'second builder commit'
  head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
  git -C "$FX_CLONE" worktree remove --force "$scratch"
  say "launch=$launch  branch head=$head  copy HEAD=$(git -C "$FX_WT" rev-parse HEAD) ($(git -C "$FX_WT" status --porcelain | wc -l) dirty paths, $(git -C "$FX_WT" symbolic-ref -q HEAD || echo detached))"
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" || fail "offer failed"
  say "offer head=$(record_field "$FX_OFFER" head) branch=$(record_field "$FX_OFFER" branch)"
  prepare_landing_row land-app || { echo "SKIP no tasks-axi"; return 0; }
  approve_current_offer
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" || fail "landing failed"
  say "parent main now at $(git -C "$FX_MAIN/projects/app" rev-parse main); receipt head=$(record_field "$FX_CHILD/state/$FX_TASK.local-receipt" head)"
  git -C "$FX_WT" merge-base --is-ancestor "$launch" "$head" && say "launch IS an ancestor of landed head"
  say "fm-teardown.sh $FX_TASK (child home)"
  status=0
  out=$(run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" 2>&1) || status=$?
  printf '%s\n' "$out"
  say "teardown exit=$status; meta present? $( [ -e "$FX_CHILD/state/$FX_TASK.meta" ] && echo yes || echo no ); copy dir present? $( [ -d "$FX_WT" ] && echo yes || echo no )"
  [ "$status" = 0 ] || fail "REPORTED SHAPE: teardown refused a copy behind the landed head"
  pass "reported shape: copy detached at launch, ancestor of landed head, tears down"
}

scenario_behind_unlanded_offer_refuses() {
  local launch head err status out
  make_bound_fixture unlanded tf-sell-now
  launch=$(git -C "$FX_WT" rev-parse HEAD)
  commit_child_work 'offered but never landed'
  head=$(git -C "$FX_WT" rev-parse HEAD)
  git -C "$FX_WT" checkout -q --detach "$launch"
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null || fail "offer failed"
  say "copy HEAD=$launch (ancestor of offered $head); NO landing performed, no receipt"
  status=0
  out=$(run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" 2>&1) || status=$?
  printf '%s\n' "$out"
  say "teardown exit=$status; meta present? $( [ -e "$FX_CHILD/state/$FX_TASK.meta" ] && echo yes || echo no )"
  [ "$status" = 1 ] || fail "teardown accepted an ancestor copy of an UNLANDED offer"
  printf '%s' "$out" | grep -q "no durable proof that $head reached the parent's default branch" || fail "refusal did not cite missing landing proof"
  [ -e "$FX_CHILD/state/$FX_TASK.meta" ] || fail "refused teardown removed the record"
  pass "copy behind an unlanded offer still refuses for lack of a receipt"
}

for t in "$@"; do say "RUN $t"; "$t"; done
