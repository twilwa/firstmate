#!/usr/bin/env bash
# Behavioral coverage for the read-only night ledger built from review ledgers,
# a fixture git clone, and a stubbed gh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NIGHT="$ROOT/bin/fm-night-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-night-ledger-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-} ${2:-}" = "pr view" ] || { printf 'unexpected gh call: %s\n' "$*" >&2; exit 91; }
n=${3##*/}
cat "$FM_TEST_GH_DIR/$n.json"
SH
chmod +x "$FAKEBIN/gh"

CASE=
new_case() { # name: fresh home, clone, and gh fixture directory
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home/data/pr-review-ledger" "$CASE/gh"
  fm_git_init_commit "$CASE/home/projects/r"
  git -C "$CASE/home/projects/r" remote add origin https://github.com/o/r.git
}

commit_on_dev() { # file subject -> prints the new commit sha
  local repo="$CASE/home/projects/r"
  printf '%s\n' "$2" >> "$repo/$1"
  git -C "$repo" add "$1"
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm "$2"
  git -C "$repo" update-ref refs/remotes/origin/dev HEAD
  git -C "$repo" rev-parse HEAD
}

# merged_pr number decision-epoch merged-iso merge-sha files-json issues-json risk [post-merge-json]
merged_pr() {
  local n=$1 epoch=$2 merged_at=$3 sha=$4 files=$5 issues=$6 risk=$7 post=${8:-}
  local url="https://github.com/o/r/pull/$n" head
  head=$(printf '%040d' "$n")
  jq -n --arg url "$url" --arg head "$head" --argjson epoch "$epoch" --arg risk "$risk" \
    --argjson post "${post:-[]}" '{
      schema:"firstmate-pr-review-ledger.v1",task:"t",url:$url,current_head:$head,
      generations:[{head:$head,risk:{level:$risk,reason:"fixture"},
        review_items:[{kind:"top-level",id:"1",author:"sourcery",disposition:"addressed",evidence:"e"}],
        attestations:[{kind:"no-mistakes",head:$head,model:"claude-opus-5-5",evidence:"run"}],
        merge_decision:{decision:"merge",reviewed_head:$head,verified_head:$head,
          verified_epoch:$epoch,allowed_red_check:null,allowed_red_checks:[]},
        post_merge_verifications:$post}]}' \
    > "$CASE/home/data/pr-review-ledger/github--o--r--$n.json"
  jq -n --arg title "PR $n title" --arg merged_at "$merged_at" --arg sha "$sha" \
    --argjson files "$files" --argjson issues "$issues" '{
      title:$title,state:"MERGED",mergedAt:$merged_at,baseRefName:"dev",
      mergeCommit:{oid:$sha},files:($files | map({path:.})),
      closingIssuesReferences:($issues | map({number:.,url:("https://github.com/o/r/issues/" + tostring)}))}' \
    > "$CASE/gh/$n.json"
}

night() {
  FM_HOME="$CASE/home" FM_TEST_GH_DIR="$CASE/gh" PATH="$FAKEBIN:$PATH" "$NIGHT" "$@"
}

NA_POST='[{"applicability":"not-applicable","reason":"tooling","head":"x","forge_merge_sha":"x"}]'

test_contiguous_window_lists_merges_newest_first_with_one_range_revert() {
  local a b out
  new_case contiguous
  commit_on_dev before.txt 'before the night' >/dev/null
  a=$(commit_on_dev a.txt 'first merge')
  b=$(commit_on_dev b.txt 'second merge')
  merged_pr 11 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[501]' high "$NA_POST"
  merged_pr 12 1200 2026-11-27T02:00:00Z "$b" '["b.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000) || fail "contiguous night ledger exits 0"
  case "$out" in
    *pull/12*pull/11*) : ;;
    *) fail "merges are listed newest first"$'\n'"$out" ;;
  esac
  assert_contains "$out" 'gh pr revert https://github.com/o/r/pull/12' "each merge carries its revert command"
  assert_contains "$out" 'gh pr revert https://github.com/o/r/pull/11' "each merge carries its revert command"
  assert_contains "$out" "git revert --no-edit $a^..$b" "a contiguous night prints one range revert"
  assert_contains "$out" 'gh issue reopen 501 --repo o/r' "closed issues get reopen lines"
  assert_contains "$out" 'PR 11 title' "rows carry the PR title"
  assert_contains "$out" 'claude-opus-5-5' "rows carry the validation"
  assert_contains "$out" 'not reverted' "issues and comments filed overnight are named as not reverted"
  out=$(night --since 1000 --until 2000 --json) || fail "contiguous --json exits 0"
  assert_equals '12 11' "$(printf '%s' "$out" | jq -r '[.merges[].number] | join(" ")')" "json merges are newest first"
  assert_equals contiguous "$(printf '%s' "$out" | jq -r '.whole_night[0].status')" "json reports contiguity"
  assert_equals "git revert --no-edit $a^..$b" "$(printf '%s' "$out" | jq -r '.whole_night[0].commands[0]')" "json carries the range revert"
  assert_equals 'gh issue reopen 501 --repo o/r' "$(printf '%s' "$out" | jq -r '.not_undone.closed_issues[0].reopen')" "json carries reopen lines"
  pass "a contiguous window lists merges newest first with one range revert"
}

test_non_contiguous_window_names_interleaved_commits() {
  local a b out
  new_case interleaved
  a=$(commit_on_dev a.txt 'first merge')
  commit_on_dev hotfix.txt 'daytime hotfix outside the ledger' >/dev/null
  b=$(commit_on_dev b.txt 'second merge')
  merged_pr 21 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  merged_pr 22 1200 2026-11-27T02:00:00Z "$b" '["b.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000) || fail "non-contiguous night ledger exits 0"
  assert_contains "$out" 'not contiguous' "a split night says it is not contiguous"
  assert_contains "$out" 'daytime hotfix outside the ledger' "the interleaved commit is named"
  assert_not_contains "$out" "^.." "no range revert is offered for a split night"
  out=$(night --since 1000 --until 2000 --json) || fail "non-contiguous --json exits 0"
  assert_equals not-contiguous "$(printf '%s' "$out" | jq -r '.whole_night[0].status')" "json reports the split"
  assert_equals 'daytime hotfix outside the ledger' "$(printf '%s' "$out" | jq -r '.whole_night[0].interleaved[0].subject')" "json names the interleaved commit"
  assert_equals 0 "$(printf '%s' "$out" | jq -r '.whole_night[0].commands | length')" "json offers no range command"
  pass "a non-contiguous window names the interleaved commits"
}

test_revert_together_marks_later_merges_touching_the_same_files() {
  local a b c out
  new_case together
  a=$(commit_on_dev shared.txt 'first touches shared')
  b=$(commit_on_dev other.txt 'second touches other')
  c=$(commit_on_dev shared.txt 'third touches shared again')
  merged_pr 31 1100 2026-11-27T01:00:00Z "$a" '["shared.txt","a.txt"]' '[]' low "$NA_POST"
  merged_pr 32 1200 2026-11-27T02:00:00Z "$b" '["other.txt"]' '[]' low "$NA_POST"
  merged_pr 33 1300 2026-11-27T03:00:00Z "$c" '["shared.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "revert-together --json exits 0"
  assert_equals 'https://github.com/o/r/pull/33 shared.txt' \
    "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 31) | .revert_together | map("\(.url) \(.files | join(","))") | join(";")')" \
    "the earlier merge is marked to revert together with the later one on the same file"
  assert_equals 0 "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 32) | .revert_together | length')" \
    "a merge sharing no files carries no mark"
  assert_equals 0 "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 33) | .revert_together | length')" \
    "the latest merge has no later merge to mark"
  out=$(night --since 1000 --until 2000) || fail "revert-together text exits 0"
  assert_contains "$out" 'revert together with: https://github.com/o/r/pull/33 (shared: shared.txt)' "the text names the mark"
  pass "revert-together marks later merges that touched the same files"
}

test_empty_window_reports_no_merges() {
  local a out
  new_case empty
  a=$(commit_on_dev a.txt 'merged before the night')
  merged_pr 41 500 2026-11-26T20:00:00Z "$a" '["a.txt"]' '[7]' low "$NA_POST"
  out=$(night --since 1000 --until 2000) || fail "empty night ledger exits 0"
  assert_contains "$out" 'No merges recorded in this window.' "an empty window says so"
  assert_not_contains "$out" 'pull/41' "a merge decided before the window is excluded"
  assert_not_contains "$out" 'gh issue reopen' "an empty window has nothing to reopen"
  out=$(night --since 1000 --until 2000 --json) || fail "empty --json exits 0"
  assert_equals '0 0 0' "$(printf '%s' "$out" | jq -r '[(.merges | length), (.whole_night | length), (.not_undone.closed_issues | length)] | join(" ")')" \
    "json carries empty merges, whole-night, and reopen lists"
  pass "an empty window reports no merges"
}

test_missing_post_merge_data_is_reported_not_recorded() {
  local a out
  new_case no-post-merge
  a=$(commit_on_dev a.txt 'merge without a post-merge record')
  merged_pr 51 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' high
  out=$(night --since 1000 --until 2000) || fail "missing post-merge night ledger exits 0"
  assert_contains "$out" 'post-merge: not recorded' "a ledger without post-merge data says not recorded"
  assert_contains "$out" "as $a" "the merged commit still comes from the forge"
  out=$(night --since 1000 --until 2000 --json) || fail "missing post-merge --json exits 0"
  assert_equals "false $a" "$(printf '%s' "$out" | jq -r '.merges[0] | "\(.post_merge.recorded) \(.merged_commit)"')" \
    "json marks the post-merge record absent and keeps the merged commit"
  pass "missing post-merge data is reported as not recorded"
}

fm_test_run \
  test_contiguous_window_lists_merges_newest_first_with_one_range_revert \
  test_non_contiguous_window_names_interleaved_commits \
  test_revert_together_marks_later_merges_touching_the_same_files \
  test_empty_window_reports_no_merges \
  test_missing_post_merge_data_is_reported_not_recorded
