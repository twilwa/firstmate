#!/usr/bin/env bash
# Evidence driver: drives the real bin/fm-local-handoff.sh offer and
# bin/fm-merge-local.sh land-app against disposable homes built by the
# repository's own make_bound_fixture helper.
TREE=$1
. "$TREE/tests/handoff-helpers-only.sh"
echo "### tree: $TREE  (ROOT=$ROOT)"
show_meta() { echo "  meta spawn_gen lines: $(grep -c '^spawn_gen=' "$FX_CHILD/state/$FX_TASK.meta") -> $(grep '^spawn_gen=' "$FX_CHILD/state/$FX_TASK.meta" | tr '\n' ' ')"; }
offer_case() {  # <label> [line...]
  local label=$1; shift
  make_bound_fixture "offer-$label"
  set_child_spawn_gen_lines "$@"
  commit_child_work "$label change"
  echo "--- OFFER case: $label"
  show_meta
  local err="$TMP_ROOT/$label.err" st=0
  run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null 2>"$err" || st=$?
  echo "  \$ fm-local-handoff.sh offer $FX_TASK  -> exit $st"
  sed 's/^/  stderr: /' "$err"
  if [ -f "$FX_OFFER" ]; then echo "  offer published: spawn_gen=$(record_field "$FX_OFFER" spawn_gen)"; else echo "  offer published: NONE"; fi
}
offer_case absent
offer_case literal-zero 'spawn_gen=0'
offer_case digits 'spawn_gen=7'
offer_case current-token 'spawn_gen=s1795670254.12.34'
offer_case empty 'spawn_gen='
offer_case duplicate-conflicting 'spawn_gen=7' 'spawn_gen=s1795670254.12.34'
offer_case duplicate-identical 'spawn_gen=7' 'spawn_gen=7'
offer_case malformed 'spawn_gen=abc'

land() {  # <label>
  local err="$TMP_ROOT/land.err" st=0 before
  before=$(git -C "$FX_MAIN/projects/app" rev-parse main)
  run_home "$FX_MAIN" "$MERGE" land-app --offer "$FX_OFFER" --expect-head "$head" >/dev/null 2>"$err" || st=$?
  echo "--- LAND case: $1"; show_meta
  echo "  \$ fm-merge-local.sh land-app --offer <offer> --expect-head $head  -> exit $st"
  sed 's/^/  stderr: /' "$err" | tail -3
  echo "  primary main before=$before after=$(git -C "$FX_MAIN/projects/app" rev-parse main)"
}
echo; echo "=== Pinned legacy (absent) offer, then damage the child record before landing"
make_bound_fixture pinned-legacy
set_child_spawn_gen_lines
commit_child_work 'legacy change'
head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null || echo "OFFER FAILED"
echo "offer pinned spawn_gen=$(record_field "$FX_OFFER" spawn_gen) head=$head"
prepare_landing_row land-app || echo "NO TASKS-AXI"
approve_current_offer
set_child_spawn_gen_lines 'spawn_gen='; land "empty field"
set_child_spawn_gen_lines 'spawn_gen=0' 'spawn_gen=8'; land "duplicate 0 then 8 (first matches pin)"
set_child_spawn_gen_lines 'spawn_gen=0'; land "literal 0 restored (equals legacy pin)"

echo; echo "=== Pinned current-token offer, then respawn to a new current token"
make_bound_fixture pinned-token child-task s1795670254.12.34
commit_child_work 'token change'
head=$(git -C "$FX_CLONE" rev-parse "refs/heads/fm/$FX_TASK")
run_home "$FX_CHILD" "$HANDOFF" offer "$FX_TASK" >/dev/null || echo "OFFER FAILED"
echo "offer pinned spawn_gen=$(record_field "$FX_OFFER" spawn_gen) head=$head"
prepare_landing_row land-app || echo "NO TASKS-AXI"
approve_current_offer
set_child_spawn_gen_lines 'spawn_gen=s1795670254.12.340'; land "current-token mismatch"
set_child_spawn_gen_lines 'spawn_gen=s1795670254.12.34' 'spawn_gen=s1795670254.12.34'; land "duplicate identical token"
set_child_spawn_gen_lines 'spawn_gen=s1795670254.12.34'; land "token restored"
[ -f "$FX_LANDING_RECORD" ] && echo "  landing receipt spawn_gen=$(record_field "$FX_LANDING_RECORD" spawn_gen)"
