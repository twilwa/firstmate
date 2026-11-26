#!/usr/bin/env bash
# Drive the real bin/fm-pr-merge.sh and bin/fm-pr-review.sh merge with the
# bbchat check names from the owner's allowance, against a disposable FM_HOME,
# state dir and worktree, with gh faked at the forge boundary by the repository's
# own fixture helpers. Prints one transcript block per scenario.
set -u
WT=$1
TMPF=$(mktemp "${TMPDIR:-/tmp}/fm-drive.XXXXXX.sh")
sed -e "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$WT/tests/lib.sh\"#" \
    -e '/^test_[a-z0-9_]*$/d' "$WT/tests/fm-pr-merge.test.sh" > "$TMPF"
. "$TMPF"; rm -f "$TMPF"
set +e

S1='dev-browser (shard 1) / check'
S2='dev-browser (shard 2) / check'
L='dev-gate / lint'
W='dev-gate / web-tests'
HEAD_SHA=b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0

show() { # name case_dir rc
  local name=$1 c=$2 rc=$3
  echo "----- SCENARIO: $name"
  echo "exit code: $rc"
  echo "stderr:"; sed 's/^/  | /' "$c/stderr"
  echo "stdout:"; sed 's/^/  | /' "$c/stdout"
  echo "gh merge call: $(grep '^pr merge ' "$c/gh.log" 2>/dev/null || echo NONE)"
  echo "gh calls total: $( [ -f "$c/gh.log" ] && wc -l < "$c/gh.log" || echo 0)"
  echo "task meta merge_allow_red: $(grep '^merge_allow_red=' "$c/state/task-x1.meta" 2>/dev/null || echo ABSENT)"
  echo
}

newcase() { # name, then rollup entries
  local c; c=$(make_case "$1"); shift
  mkdir -p "$c/wt"; add_gh_mocks "$c" "$HEAD_SHA"
  write_github_rollup_json "$c" "$HEAD_SHA" "$@"
  printf '%s\n' "$c"
}
U=https://github.com/example/bbchat/pull/
GREEN="$(check_run 'dev-gate / typecheck' COMPLETED SUCCESS)"

echo "===== fm-pr-merge.sh --help (usage excerpt)"
"$WT/bin/fm-pr-merge.sh" --help 2>&1 | grep -n -i -- 'allow-red\|allow-missing' ; echo "help exit: ${PIPESTATUS[0]}"; echo

c=$(newcase bb-three-red "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$W" COMPLETED FAILURE)" "$GREEN")
run_pr_merge "$c" task-x1 ${U}201 --allow-red "$S1" --allow-red "$S2" --allow-red "$W" >"$c/stdout" 2>"$c/stderr"; show "three bbchat red checks, each named once -> merges" "$c" $?

c=$(newcase bb-four-red "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$L" COMPLETED FAILURE)" "$(check_run "$W" COMPLETED FAILURE)" "$GREEN")
run_pr_merge "$c" task-x1 ${U}202 --allow-red "$S1" --allow-red "$S2" --allow-red "$L" --allow-red "$W" >"$c/stdout" 2>"$c/stderr"; show "all four allowance checks red, four names (the cap) -> merges" "$c" $?

c=$(newcase bb-two-red-two-green "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$L" COMPLETED SUCCESS)" "$(check_run "$W" COMPLETED SUCCESS)")
run_pr_merge "$c" task-x1 ${U}203 --allow-red "$S1" --allow-red "$S2" --allow-red "$L" --allow-red "$W" >"$c/stdout" 2>"$c/stderr"; show "two red + two named-but-green checks -> merges (green waiver harmless)" "$c" $?

c=$(newcase bb-unnamed-red "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$W" COMPLETED FAILURE)" "$(check_run 'dev-gate / typecheck' COMPLETED FAILURE)")
run_pr_merge "$c" task-x1 ${U}204 --allow-red "$S1" --allow-red "$S2" --allow-red "$W" >"$c/stdout" 2>"$c/stderr"; show "ADVERSARIAL: three named + a fourth unnamed red check -> refuses" "$c" $?

c=$(newcase bb-prefix "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)")
run_pr_merge "$c" task-x1 ${U}205 --allow-red 'dev-browser' --allow-red "$S2" >"$c/stdout" 2>"$c/stderr"; show "ADVERSARIAL: prefix name 'dev-browser' does not waive '$S1' -> refuses" "$c" $?

c=$(newcase bb-dup "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)"); : > "$c/gh.log"
run_pr_merge "$c" task-x1 ${U}206 --allow-red "$S1" --allow-red "$S2" --allow-red "$S1" >"$c/stdout" 2>"$c/stderr"; show "ADVERSARIAL: duplicate name -> refuses before any forge call" "$c" $?

c=$(newcase bb-five "$(check_run "$S1" COMPLETED FAILURE)"); : > "$c/gh.log"
run_pr_merge "$c" task-x1 ${U}207 --allow-red "$S1" --allow-red "$S2" --allow-red "$L" --allow-red "$W" --allow-red 'dev-gate / typecheck' >"$c/stdout" 2>"$c/stderr"; show "ADVERSARIAL: five names -> refuses before any forge call" "$c" $?

c=$(newcase bb-joined "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)"); : > "$c/gh.log"
run_pr_merge "$c" task-x1 ${U}208 --allow-red "$S1,$S2" >"$c/stdout" 2>"$c/stderr"; show "ADVERSARIAL: two names packed in one argument (comma) waive neither -> refuses" "$c" $?

c=$(newcase bb-away "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)")
write_away_record "$c"; : > "$c/gh.log"
run_pr_merge "$c" task-x1 ${U}209 --allow-red "$S1" --allow-red "$S2" >"$c/stdout" 2>"$c/stderr"; show "ADVERSARIAL: away record present -> refuses" "$c" $?

c=$(newcase bb-missing-required "$(check_run "$S1" COMPLETED FAILURE)" "$GREEN")
write_github_required "$c" "classic:$S1" "classic:$S2"
run_pr_merge "$c" task-x1 ${U}210 --allow-red "$S1" --allow-red "$S2" >"$c/stdout" 2>"$c/stderr"; show "ADVERSARIAL: required '$S2' never reported; --allow-red does not waive a missing required check -> refuses" "$c" $?

c=$(newcase bb-unreadable-required "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)")
printf "HTTP 502: read failed" > "$c/github-branch-fail"; printf "HTTP 502: read failed" > "$c/github-required-rules-fail"
run_pr_merge "$c" task-x1 ${U}211 --allow-red "$S1" --allow-red "$S2" >"$c/stdout" 2>"$c/stderr"; show "ADVERSARIAL: required-check source unreadable; waivers do not bypass -> refuses" "$c" $?

c=$(newcase bb-stale-head "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)")
FM_PR_REVIEW_EXPECTED_HEAD= run_pr_merge "$c" task-x1 ${U}212 --expected-head cccccccccccccccccccccccccccccccccccccccc --allow-red "$S1" --allow-red "$S2" >"$c/stdout" 2>"$c/stderr"; show "ADVERSARIAL: waivers still bind the head; --expected-head mismatch -> refuses" "$c" $?

low='[{"filename":"tests/widget.test.sh","status":"modified","additions":10,"deletions":2}]'
c=$(newcase bb-wrapper "$(check_run "$S1" COMPLETED FAILURE)" "$(check_run "$S2" COMPLETED FAILURE)" "$(check_run "$W" COMPLETED FAILURE)" "$GREEN")
mkdir -p "$c/home"; review_pull_request_for_merge "$c" 213 "$low" no-attest >/dev/null 2>&1
FM_TEST_MERGE_VIA_REVIEW=1 FM_TEST_HOME="$c/home" run_pr_merge "$c" task-x1 https://github.com/example/repo/pull/213 --allow-red "$S1" --allow-red "$S2" --allow-red "$W" >"$c/stdout" 2>"$c/stderr"; rc=$?
show "fm-pr-review.sh merge forwards three waivers -> merges" "$c" $rc
echo "review ledger merge_decision: $(jq -c '.generations[-1].merge_decision | {decision, allowed_red_checks, allowed_red_check}' "$c/home/data/pr-review-ledger/github--example--repo--213.json" 2>&1)"
echo "===== DRIVER DONE"
