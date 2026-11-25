#!/usr/bin/env bash
# Guards that must hold for every waiver: missing/unreadable required source, head binding.
. "$1"
set +e
S1='dev-browser (shard 1) / check'; S2='dev-browser (shard 2) / check'; LINT='dev-gate / lint'; WEB='dev-gate / web-tests'
head=d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0
other=e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0
report() { local case_dir=$1 rc=$2
  echo "--- stderr"; grep -v '^●' "$case_dir/stderr"
  echo "--- forge merge calls:"; grep '^pr merge' "$case_dir/gh.log" || echo "(none)"
  echo "exit=$rc expected=nonzero-and-no-merge => $([ "$rc" != 0 ] && ! grep -q '^pr merge' "$case_dir/gh.log" && echo OK || echo MISMATCH)"; }
base() { case_dir=$(make_case "bb2-$1"); mkdir -p "$case_dir/wt"; add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$LINT" COMPLETED FAILURE)"; }

base missing-required
write_github_required "$case_dir" classic:"$WEB"
echo "################ missing-required-check-named-in-waivers (required '$WEB' never reported)"
run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/501 --allow-red "$S1" --allow-red "$S2" --allow-red "$WEB" > "$case_dir/stdout" 2> "$case_dir/stderr"; report "$case_dir" $?

for src in branch rules; do
  base "unreadable-$src"
  write_github_required "$case_dir" classic:"$LINT"
  case $src in branch) printf 'read failed' > "$case_dir/github-branch-fail" ;; rules) printf 'read failed' > "$case_dir/github-required-rules-fail" ;; esac
  echo "################ unreadable-required-source-$src with three waivers"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/50$([ $src = branch ] && echo 2 || echo 3) --allow-red "$S1" --allow-red "$S2" --allow-red "$LINT" > "$case_dir/stdout" 2> "$case_dir/stderr"; report "$case_dir" $?
done

base moved-head
echo "################ expected-head-mismatch with three waivers (live head $head, expected $other)"
run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/504 --expected-head "$other" --allow-red "$S1" --allow-red "$S2" --allow-red "$LINT" > "$case_dir/stdout" 2> "$case_dir/stderr"; report "$case_dir" $?

# Five names through the review wrapper
case_dir=$(make_case bb2-review-five); mkdir -p "$case_dir/wt" "$case_dir/home"; add_gh_mocks "$case_dir" "$head"
review_pull_request_for_merge "$case_dir" 505 '[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]' no-attest
: > "$case_dir/gh.log"
echo "################ review-wrapper-five-names"
FM_TEST_MERGE_VIA_REVIEW=1 FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/505 \
  --allow-red "$S1" --allow-red "$S2" --allow-red "$LINT" --allow-red "$WEB" --allow-red 'dev-gate / unit' > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
report "$case_dir" $rc
echo "--- ledger merge_decision: $(jq -c '.generations[-1].merge_decision' "$case_dir/home/data/pr-review-ledger/github--example--repo--505.json")"
