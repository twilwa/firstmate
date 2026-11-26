#!/usr/bin/env bash
# Drives the real bin/fm-pr-merge.sh (and fm-pr-review.sh merge) against a
# disposable fake GitHub forge (gh shim from tests/fm-pr-merge.test.sh) using
# the exact bbchat check names from the owner's 2026-11-25 allowance.
EV=$(cd "$(dirname "$0")" && pwd)
source "$EV/scratch/merge-defs.sh"
set +e
S1='dev-browser (shard 1) / check'; S2='dev-browser (shard 2) / check'
L='dev-gate / lint'; WT='dev-gate / web-tests'; G='api / test'
HEAD_SHA=b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0
n=0
scenario() {  # name expected_rc setup_fn -- args...
  local name=$1 want=$2 setup=$3 case_dir rc merged meta; shift 4; n=$((n+1))
  case_dir=$(make_case "bbchat-$n"); mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$HEAD_SHA"
  $setup "$case_dir"
  run_pr_merge "$case_dir" task-x1 "https://github.com/example/bbchat/pull/$((200+n))" "$@" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  merged=$(grep '^pr merge ' "$case_dir/gh.log" || echo '(no gh pr merge call)')
  meta=$(grep '^merge_allow_red=' "$case_dir/state/task-x1.meta" || echo '(no merge_allow_red= line)')
  echo "=== $name"
  printf '$ fm-pr-merge.sh task-x1 <pr>'; printf ' %q' "$@"; echo
  echo "exit=$rc (expected $want) -> $([ "$rc" = "$want" ] && echo MATCH || echo MISMATCH)"
  echo "forge merge call: $merged"
  echo "task meta: $meta"
  echo "forge calls total: $(wc -l < "$case_dir/gh.log")"
  sed 's/^/stderr: /' "$case_dir/stderr" | head -12
  echo
}
four_red()   { write_github_rollup_json "$1" "$HEAD_SHA" "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$L" COMPLETED FAILURE)" "$(check_run "$WT" COMPLETED FAILURE)" "$(check_run "$G" COMPLETED SUCCESS)"; }
three_red()  { write_github_rollup_json "$1" "$HEAD_SHA" "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$L" COMPLETED FAILURE)" "$(check_run "$WT" COMPLETED SUCCESS)" "$(check_run "$G" COMPLETED SUCCESS)"; }
two_red()    { write_github_rollup_json "$1" "$HEAD_SHA" "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$L" COMPLETED SUCCESS)" "$(check_run "$G" COMPLETED SUCCESS)"; }
three_red_plus_unnamed_api() { write_github_rollup_json "$1" "$HEAD_SHA" "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$L" COMPLETED FAILURE)" "$(check_run "$G" COMPLETED FAILURE)"; }
three_red_away() { three_red "$1"; write_away_record "$1" --words 'merge task-x1 when green'; }
three_red_required_missing() { three_red "$1"; write_github_required "$1" "classic:$WT" "classic:deploy / preview"; write_github_rollup_json "$1" "$HEAD_SHA" "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$L" COMPLETED FAILURE)" "$(check_run "$G" COMPLETED SUCCESS)"; }
three_red_required_unreadable() { three_red "$1"; : > "$1/github-branch-fail"; }
three_red_head_moved() { three_red "$1"; }

scenario "two bbchat browser-shard waivers merge when exactly those are red" 0 two_red -- --allow-red "$S1" --allow-red "$S2"
scenario "three bbchat waivers merge when exactly those three are red" 0 three_red -- --allow-red "$S1" --allow-red "$S2" --allow-red "$L"
scenario "all four allowed bbchat waivers (max) merge when exactly those four are red" 0 four_red -- --allow-red "$S1" --allow-red "$S2" --allow-red "$L" --allow-red "$WT"
scenario "a named waiver whose check is green is harmless (web-tests named but green)" 0 three_red -- --allow-red "$S1" --allow-red "$S2" --allow-red "$L" --allow-red "$WT"
scenario "an unnamed fourth red check (api / test) refuses" 1 three_red_plus_unnamed_api -- --allow-red "$S1" --allow-red "$S2" --allow-red "$L"
scenario "only three of four reds named (web-tests left out) refuses" 1 four_red -- --allow-red "$S1" --allow-red "$S2" --allow-red "$L"
scenario "a duplicate waiver name refuses before any forge call" 2 three_red -- --allow-red "$S1" --allow-red "$S2" --allow-red "$S1"
scenario "five waiver names refuse before any forge call" 2 four_red -- --allow-red "$S1" --allow-red "$S2" --allow-red "$L" --allow-red "$WT" --allow-red "$G"
scenario "a name fragment is not an exact match (dev-gate only) refuses" 1 three_red -- --allow-red "$S1" --allow-red "$S2" --allow-red "dev-gate"
scenario "away record present: multiple waivers refuse" 2 three_red_away -- --allow-red "$S1" --allow-red "$S2" --allow-red "$L"
scenario "a required check that never reported is not waived by naming it" 1 three_red_required_missing -- --allow-red "$S1" --allow-red "$S2" --allow-red "$L" --allow-red "$WT"
scenario "an unreadable required-check source refuses even with waivers" 1 three_red_required_unreadable -- --allow-red "$S1" --allow-red "$S2" --allow-red "$L"
scenario "waivers still bind the reviewed head: a mismatched --expected-head refuses" 1 three_red -- --expected-head cccccccccccccccccccccccccccccccccccccccc --allow-red "$S1" --allow-red "$S2" --allow-red "$L"
scenario "--allow-missing is unchanged: still single use" 2 three_red -- --allow-missing x --allow-missing y
scenario "the old equals form --allow-red=name is refused" 2 three_red -- "--allow-red=$S1"
