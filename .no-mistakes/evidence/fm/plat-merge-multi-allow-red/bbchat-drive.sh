#!/usr/bin/env bash
# Drive the real bin/fm-pr-merge.sh against a disposable fake GitHub forge
# with the bbchat check names from the owner's allowance.
. "$1"
set +e
S1='dev-browser (shard 1) / check'; S2='dev-browser (shard 2) / check'
LINT='dev-gate / lint'; WEB='dev-gate / web-tests'
head=b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0
drive() { # label pr expected-rc rollup-entries... -- args...
  local label=$1 pr=$2 want=$3 entries=() case_dir rc; shift 3
  while [ "$1" != -- ]; do entries+=("$1"); shift; done; shift
  case_dir=$(make_case "bb-$label"); mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" "${entries[@]}"
  echo "################ $label"
  printf '$ fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/%s' "$pr"; printf ' %q' "$@"; echo
  run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$pr" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  echo "--- stdout"; cat "$case_dir/stdout"; echo "--- stderr"; cat "$case_dir/stderr"
  echo "--- forge merge calls:"; grep '^pr merge' "$case_dir/gh.log" || echo "(none)"
  echo "--- forge calls total: $(wc -l < "$case_dir/gh.log")"
  echo "exit=$rc expected=$want => $([ "$rc" = "$want" ] && echo OK || echo MISMATCH)"
}
G="$(check_run 'dev-gate / unit' COMPLETED SUCCESS)"
drive three-red-three-waivers 301 0 "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$LINT" COMPLETED FAILURE)" "$G" -- \
  --allow-red "$S1" --allow-red "$S2" --allow-red "$LINT"
drive four-red-four-waivers 302 0 "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$LINT" COMPLETED FAILURE)" "$(check_run "$WEB" COMPLETED FAILURE)" "$G" -- \
  --allow-red "$S1" --allow-red "$S2" --allow-red "$LINT" --allow-red "$WEB"
drive unnamed-fifth-red 303 1 "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$LINT" COMPLETED FAILURE)" "$(check_run "$WEB" COMPLETED FAILURE)" "$(check_run 'dev-gate / unit' COMPLETED FAILURE)" -- \
  --allow-red "$S1" --allow-red "$S2" --allow-red "$LINT" --allow-red "$WEB"
drive prefix-is-not-exact 304 1 "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$G" -- \
  --allow-red 'dev-browser' --allow-red "$S2"
drive named-green-harmless 305 0 "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED SUCCESS)" "$G" -- \
  --allow-red "$S1" --allow-red "$S2"
drive duplicate-refused 306 2 "$(check_run "$S1" COMPLETED FAILURE)" -- \
  --allow-red "$S1" --allow-red "$S2" --allow-red "$S1"
drive five-names-refused 307 2 "$(check_run "$S1" COMPLETED FAILURE)" -- \
  --allow-red "$S1" --allow-red "$S2" --allow-red "$LINT" --allow-red "$WEB" --allow-red 'dev-gate / unit'
drive pending-not-waived 308 1 "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" IN_PROGRESS -)" "$G" -- \
  --allow-red "$S1"
# away posture with several waivers
case_dir=$(make_case bb-away); mkdir -p "$case_dir/wt"; add_gh_mocks "$case_dir" "$head"
write_github_rollup_json "$case_dir" "$head" "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)"
write_away_record "$case_dir" --words 'keep the lanes running'
echo "################ away-record-several-waivers"
run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/309 --allow-red "$S1" --allow-red "$S2" > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
echo "--- stderr"; cat "$case_dir/stderr"; echo "--- forge merge calls:"; grep '^pr merge' "$case_dir/gh.log" || echo "(none)"
echo "exit=$rc expected=nonzero => $([ "$rc" != 0 ] && echo OK || echo MISMATCH)"
echo "################ help"
"$ROOT/bin/fm-pr-merge.sh" --help 2>&1 | grep -n -i -A6 'allow-red' | head -40
