# Drives the reported trading-floor shape against real fm-local-handoff/fm-merge-local/fm-teardown:
# builder commits on fm/<task> in the bound clone, the task copy stays detached at its launch
# commit (an ancestor of the landed head), the parent lands, then the child runs teardown.
. "$(dirname "$0")/focused-runner.sh"
make_bound_fixture "transcript-$1" tf-sell-now
launch=$(git -C "$FX_WT" rev-parse HEAD)
commit_child_work 'builder commit on fm/tf-sell-now'
head=$(git -C "$FX_WT" rev-parse HEAD)
git -C "$FX_WT" checkout -q --detach "$launch"
run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null || fail offer
prepare_landing_row land-app || fail "tasks-axi missing"
approve_current_offer
run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" >/dev/null || fail land
echo "launch commit (copy HEAD, detached): $launch"
echo "landed/offered head:                 $head"
git -C "$FX_WT" merge-base --is-ancestor "$launch" "$head" && echo "launch is an ancestor of landed head: yes"
echo "parent default branch head: $(git -C "$FX_MAIN/projects/app" rev-parse HEAD)"
echo "\$ fm-teardown.sh $FX_TASK"
st=0; run_home "$FX_CHILD" "$TEARDOWN" "$FX_TASK" 2>&1 || st=$?
echo "teardown exit=$st"
[ -e "$FX_CHILD/state/$FX_TASK.meta" ] && echo "task record: still present" || echo "task record: removed"
[ -d "$FX_WT" ] && echo "task copy: still present" || echo "task copy: removed"
