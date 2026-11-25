#!/usr/bin/env bash
# Real bin/fm-pr-review.sh merge -> real bin/fm-pr-merge.sh, disposable fake forge,
# three red bbchat checks waived; then the same with an unwaived fourth red.
. "$1"
set +e
S1='dev-browser (shard 1) / check'; S2='dev-browser (shard 2) / check'; LINT='dev-gate / lint'
head=c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0
low='[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]'
one() { # label pr extra_red(true/false)
  local label=$1 pr=$2 extra=$3 case_dir url rc checks entries
  url="https://github.com/example/repo/pull/$pr"
  case_dir=$(make_case "rv-$label"); mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  entries=("$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$LINT" COMPLETED FAILURE)" "$(check_run 'dev-gate / unit' COMPLETED "$([ "$extra" = true ] && echo FAILURE || echo SUCCESS)")")
  write_github_rollup_json "$case_dir" "$head" "${entries[@]}"
  review_pull_request_for_merge "$case_dir" "$pr" "$low" no-attest
  checks=$(jq -cn --arg a "$S1" --arg b "$S2" --arg c "$LINT" --arg x "$extra" '[
    {name:$a,state:"FAILURE",bucket:"fail",link:"https://example.test/1"},
    {name:$b,state:"FAILURE",bucket:"fail",link:"https://example.test/2"},
    {name:$c,state:"FAILURE",bucket:"fail",link:"https://example.test/3"},
    (if $x=="true" then {name:"dev-gate / unit",state:"FAILURE",bucket:"fail",link:"https://example.test/4"} else {name:"dev-gate / unit",state:"SUCCESS",bucket:"pass",link:"https://example.test/4"} end)]')
  printf '%s\n' "$checks" > "$case_dir/review-checks.json"
  sed -i 's|^  "pr checks").*|  "pr checks") cat "$case_dir/review-checks.json"; exit 1 ;;|' "$case_dir/fakebin/gh"
  # Re-review at the live red-check state so the final disposition binds to it.
  PATH="$case_dir/fakebin:$PATH" FM_HOME="$case_dir/home" FM_TEST_GH_HEAD="$case_dir/github-head" FM_TEST_GH_LOG="$case_dir/gh.log" FM_TEST_GH_VIEW_JSON="$case_dir/github-view.json" \
    "$ROOT/bin/fm-pr-review-snapshot.sh" "$url" "$case_dir/live-snapshot.json" || echo "snapshot collection failed"
  jq ".comments=[]" "$case_dir/live-snapshot.json" > "$case_dir/ls.tmp" && mv "$case_dir/ls.tmp" "$case_dir/live-snapshot.json"
  rm -rf "$case_dir/home/data/pr-review-ledger"
  FM_HOME="$case_dir/home" FM_REVIEW_NOW_EPOCH=1000 "$ROOT/bin/fm-pr-review.sh" init task-x1 "$url" --snapshot "$case_dir/live-snapshot.json" >/dev/null || echo "init failed"
  FM_HOME="$case_dir/home" FM_REVIEW_NOW_EPOCH=1600 "$ROOT/bin/fm-pr-review.sh" checkpoint "$url" --snapshot "$case_dir/live-snapshot.json" >/dev/null || echo "checkpoint failed"
  FM_HOME="$case_dir/home" "$ROOT/bin/fm-pr-review.sh" final-disposition "$url" "$head" "$url#issuecomment-901" >/dev/null || echo "final-disposition failed"
  : > "$case_dir/gh.log"
  echo "--- live snapshot checks:"; jq -c '.checks[] | {name,bucket}' "$case_dir/live-snapshot.json"
  echo "################ $label"
  printf '$ fm-pr-review.sh merge task-x1 %s' "$url"; printf ' %q' --allow-red "$S1" --allow-red "$S2" --allow-red "$LINT"; echo
  FM_TEST_MERGE_VIA_REVIEW=1 FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    --allow-red "$S1" --allow-red "$S2" --allow-red "$LINT" > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  echo "--- stdout"; cat "$case_dir/stdout"; echo "--- stderr"; grep -v '^●' "$case_dir/stderr"
  echo "--- forge merge calls:"; grep '^pr merge' "$case_dir/gh.log" || echo "(none)"
  echo "--- ledger merge_decision:"; jq '.generations[-1].merge_decision' "$case_dir/home/data/pr-review-ledger/github--example--repo--$pr.json"
  echo "exit=$rc"
}
one three-waived-rest-green 401 false
one fourth-red-unwaived 402 true
