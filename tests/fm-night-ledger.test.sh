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
case "${1:-}" in
  pr)
    n=${3##*/}
    [ "${FM_TEST_GH_STALL:-}" != "$n" ] || sleep 30
    case "${2:-}" in
      view)
        if [ -n "${FM_TEST_MUTATE_LEDGER:-}" ]; then
          # A review checkpoint publishes between the ledger read and the forge read.
          jq '.generations[].merge_decision = null' "$FM_TEST_MUTATE_LEDGER" > "$FM_TEST_MUTATE_LEDGER.new"
          mv "$FM_TEST_MUTATE_LEDGER.new" "$FM_TEST_MUTATE_LEDGER"
        fi
        # gh pr view --json files returns at most the first 100 files.
        jq '.files |= .[:100]' "$FM_TEST_GH_DIR/$n.json"
        ;;
      diff) cat "$FM_TEST_GH_DIR/$n.diff" ;;
      *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
    esac
    ;;
  api)
    shift
    paginate=0 endpoint='' expr=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --paginate) paginate=1; shift ;;
        --hostname) shift 2 ;;
        --jq) expr=$2; shift 2 ;;
        repos/*) endpoint=$1; shift ;;
        *) printf 'unexpected gh api argument: %s\n' "$1" >&2; exit 91 ;;
      esac
    done
    [[ $endpoint =~ ^repos/[^/]+/[^/]+/pulls/([0-9]+)/files\?per_page=100$ ]] \
      || { printf 'unexpected gh api endpoint: %s\n' "$endpoint" >&2; exit 91; }
    n=${BASH_REMATCH[1]}
    [ "${FM_TEST_GH_STALL:-}" != "$n" ] || sleep 30
    # The REST endpoint serves 100 files per page; without --paginate gh reads only the first.
    jq -c --argjson all "$paginate" '[.files[] | {filename:.path, previous_filename:.previous}] as $f
      | [range(0; $f | length; 100) as $i | $f[$i:$i + 100]]
      | if $all == 1 then .[] else .[:1][] end' "$FM_TEST_GH_DIR/$n.json" \
      | while IFS= read -r page; do jq -c "$expr" <<<"$page"; done
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
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
# issues-json entries are issue numbers in o/r or "owner/repo#n" strings.
# files-json entries are paths or {"path":...,"previous":...} renames.
# Optional overrides: MP_REPO (owner/name, default o/r), MP_BASE (default dev),
# MP_HEAD (the forge's merged head, default the ledger head), MP_COMMITS (commit
# count, default 1), MP_CHANGED (forge changedFiles, default the file count).
merged_pr() {
  local n=$1 epoch=$2 merged_at=$3 sha=$4 files=$5 issues=$6 risk=$7 post=${8:-}
  local repo=${MP_REPO:-o/r} url head
  url="https://github.com/$repo/pull/$n"
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
    > "$CASE/home/data/pr-review-ledger/github--${repo%%/*}--${repo#*/}--$n.json"
  jq -n --arg title "PR $n title" --arg merged_at "$merged_at" --arg sha "$sha" \
    --arg base "${MP_BASE:-dev}" --arg head "${MP_HEAD:-$head}" \
    --argjson commits "${MP_COMMITS:-1}" --argjson changed "${MP_CHANGED:-null}" \
    --argjson files "$files" --argjson issues "$issues" '{
      title:$title,state:"MERGED",mergedAt:$merged_at,baseRefName:$base,headRefOid:$head,
      mergeCommit:(if $sha == "" then null else {oid:$sha} end),
      commits:[range(0; $commits) | {oid:"c\(.)"}],
      files:($files | map(if type == "string" then {path:.} else . end)),
      changedFiles:($changed // ($files | length)),
      closingIssuesReferences:($issues | map(
        (if type == "number" then {owner:"o", name:"r", number:.}
         else capture("^(?<owner>[^/]+)/(?<name>[^#]+)#(?<number>[0-9]+)$") | .number |= tonumber end)
        | {number, url:"https://github.com/\(.owner)/\(.name)/issues/\(.number)",
           repository:{name, owner:{login:.owner}}}))}' \
    > "$CASE/gh/$n.json"
}

pr_diff() { # number from to: the forge's diff of a pull request, from the fixture clone
  git -C "$CASE/home/projects/r" diff "$2" "$3" > "$CASE/gh/$1.diff"
}

ledger_of() { # number [owner/name]
  local repo=${2:-o/r}
  printf '%s/home/data/pr-review-ledger/github--%s--%s--%s.json\n' "$CASE" "${repo%%/*}" "${repo#*/}" "$1"
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
  assert_contains "$out" 'disposable dev app' "test data on the dev app is named as not removed"
  out=$(night --since 1000 --until 2000 --json) || fail "contiguous --json exits 0"
  assert_equals '12 11' "$(printf '%s' "$out" | jq -r '[.merges[].number] | join(" ")')" "json merges are newest first"
  assert_equals contiguous "$(printf '%s' "$out" | jq -r '.whole_night[0].status')" "json reports contiguity"
  assert_equals "git revert --no-edit $a^..$b" "$(printf '%s' "$out" | jq -r '.whole_night[0].commands[0]')" "json carries the range revert"
  assert_equals 'gh issue reopen 501 --repo o/r' "$(printf '%s' "$out" | jq -r '.not_undone.closed_issues[0].reopen')" "json carries reopen lines"
  assert_equals 1 "$(printf '%s' "$out" | jq -r '[.not_undone.notes[] | select(test("disposable dev app"))] | length')" "json notes name dev app test data"
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

deep_history() { # count: append that many empty first-parent commits on dev
  local repo="$CASE/home/projects/r" from i
  from=$(git -C "$repo" rev-parse HEAD)
  for ((i = 1; i <= $1; i++)); do
    printf 'commit refs/heads/deep\ncommitter t <t@example.invalid> 1000000000 +0000\ndata 1\nc\n'
    [ "$i" -gt 1 ] || printf 'from %s\n' "$from"
    printf '\n'
  done | git -C "$repo" fast-import --quiet
  git -C "$repo" update-ref HEAD refs/heads/deep
  git -C "$repo" update-ref refs/remotes/origin/dev HEAD
}

test_split_night_on_a_long_history_is_still_not_contiguous() {
  local a b out
  new_case deep
  # More first-parent commits than fit in one 128 KiB command-line argument.
  deep_history 4000
  a=$(commit_on_dev a.txt 'first merge')
  commit_on_dev hotfix.txt 'daytime hotfix on a long history' >/dev/null
  b=$(commit_on_dev b.txt 'second merge')
  merged_pr 61 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  merged_pr 62 1200 2026-11-27T02:00:00Z "$b" '["b.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "long-history --json exits 0"
  assert_equals not-contiguous "$(printf '%s' "$out" | jq -r '.whole_night[0].status')" "a split night on a long history is not contiguous"
  assert_equals 'daytime hotfix on a long history' "$(printf '%s' "$out" | jq -r '.whole_night[0].interleaved[0].subject')" "the interleaved commit is named"
  assert_equals 0 "$(printf '%s' "$out" | jq -r '.whole_night[0].commands | length')" "no range command is offered"
  pass "a split night on a long history is still not contiguous"
}

test_merge_commit_night_offers_no_whole_night_revert() {
  local repo a m out
  new_case merge-commit
  repo="$CASE/home/projects/r"
  a=$(commit_on_dev a.txt 'first merge')
  git -C "$repo" checkout -q -b side
  printf 'side\n' > "$repo/side.txt"
  git -C "$repo" add side.txt
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'side work'
  git -C "$repo" checkout -q main
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid merge -q --no-ff -m 'second merge as a merge commit' side
  git -C "$repo" update-ref refs/remotes/origin/dev HEAD
  m=$(git -C "$repo" rev-parse HEAD)
  merged_pr 71 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  merged_pr 72 1200 2026-11-27T02:00:00Z "$m" '["side.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "merge-commit --json exits 0"
  assert_equals unknown "$(printf '%s' "$out" | jq -r '.whole_night[0].status')" "a night with a merge commit has no whole-night revert"
  assert_contains "$(printf '%s' "$out" | jq -r '.whole_night[0].reason')" "$m" "the reason names the merge commit"
  assert_equals 0 "$(printf '%s' "$out" | jq -r '.whole_night[0].commands | length')" "no whole-night command is offered"
  out=$(night --since 1000 --until 2000) || fail "merge-commit text exits 0"
  assert_contains "$out" 'gh pr revert https://github.com/o/r/pull/72' "the merge keeps its own revert command"
  assert_not_contains "$out" 'git revert' "no git revert is offered"
  pass "a night with a merge commit offers no whole-night revert"
}

test_files_past_the_first_page_still_mark_revert_together() {
  local a b many out
  new_case many-files
  a=$(commit_on_dev a.txt 'first touches many files')
  b=$(commit_on_dev b.txt 'second touches the last of them')
  many=$(jq -cn '[range(0; 101) | "f\(.).txt"]')
  merged_pr 81 1100 2026-11-27T01:00:00Z "$a" "$many" '[]' low "$NA_POST"
  merged_pr 82 1200 2026-11-27T02:00:00Z "$b" '["f100.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "many-files --json exits 0"
  assert_equals 101 "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 81) | .files | length')" "every changed file is listed"
  assert_equals 'https://github.com/o/r/pull/82 f100.txt' \
    "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 81) | .revert_together | map("\(.url) \(.files | join(","))") | join(";")')" \
    "a file past the first hundred still marks the later merge"
  pass "files past the first page still mark revert-together"
}

test_whole_night_is_unknown_without_a_merged_commit_or_origin_ref() {
  local repo a out
  new_case no-merge-commit
  commit_on_dev a.txt 'merge the forge reports no commit for' >/dev/null
  merged_pr 91 1100 2026-11-27T01:00:00Z '' '["a.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "no-merge-commit --json exits 0"
  assert_equals 'null unknown' "$(printf '%s' "$out" | jq -r '"\(.merges[0].merged_commit) \(.whole_night[0].status)"')" \
    "a merge without a forge merge commit shows it unknown and gives no whole-night revert"
  out=$(night --since 1000 --until 2000) || fail "no-merge-commit text exits 0"
  assert_contains "$out" 'into dev as unknown' "the text shows the merged commit as unknown"
  new_case no-origin-ref
  repo="$CASE/home/projects/r"
  a=$(commit_on_dev a.txt 'merge only on a local branch')
  git -C "$repo" branch dev
  git -C "$repo" update-ref -d refs/remotes/origin/dev
  merged_pr 92 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "no-origin-ref --json exits 0"
  assert_equals unknown "$(printf '%s' "$out" | jq -r '.whole_night[0].status')" "a local dev branch does not stand in for origin/dev"
  assert_contains "$(printf '%s' "$out" | jq -r '.whole_night[0].reason')" 'refs/remotes/origin/dev' "the reason names the missing ref"
  pass "the whole-night revert is unknown without a merged commit or an origin ref"
}

test_cross_repo_closed_issue_reopens_in_its_own_repo() {
  local a out
  new_case cross-repo-issue
  a=$(commit_on_dev a.txt 'merge closing issues in two repos')
  merged_pr 101 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[7,"o/other#5"]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "cross-repo --json exits 0"
  assert_equals 'gh issue reopen 7 --repo o/r;gh issue reopen 5 --repo o/other' \
    "$(printf '%s' "$out" | jq -r '[.not_undone.closed_issues[].reopen] | join(";")')" \
    "each closed issue reopens in its own repository"
  out=$(night --since 1000 --until 2000) || fail "cross-repo text exits 0"
  assert_contains "$out" 'closed issues: #7 o/other#5' "the row names the other repository's issue"
  pass "a closed issue in another repository reopens there"
}

test_legacy_single_waiver_is_listed() {
  local a out ledger
  new_case legacy-waiver
  a=$(commit_on_dev a.txt 'merge with a legacy waiver')
  merged_pr 111 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  ledger="$CASE/home/data/pr-review-ledger/github--o--r--111.json"
  jq '.generations[0].merge_decision |= (del(.allowed_red_checks) | .allowed_red_check = "e2e")' "$ledger" > "$ledger.new"
  mv "$ledger.new" "$ledger"
  out=$(night --since 1000 --until 2000 --json) || fail "legacy waiver --json exits 0"
  assert_equals '["e2e"]' "$(printf '%s' "$out" | jq -c '.merges[0].waiver')" "a legacy single waiver is listed"
  out=$(night --since 1000 --until 2000) || fail "legacy waiver text exits 0"
  assert_contains "$out" 'waiver: e2e' "the text names the legacy waiver"
  pass "a legacy single waiver is listed"
}

test_same_second_merges_use_history_order() {
  local a b out
  new_case same-second
  a=$(commit_on_dev shared.txt 'older merge in history')
  b=$(commit_on_dev shared.txt 'newer merge in history')
  # Same mergedAt second; the ledger glob reads 121 before 122.
  merged_pr 121 1200 2026-11-27T02:00:00Z "$b" '["shared.txt"]' '[]' low "$NA_POST"
  merged_pr 122 1100 2026-11-27T02:00:00Z "$a" '["shared.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "same-second --json exits 0"
  assert_equals "git revert --no-edit $a^..$b" "$(printf '%s' "$out" | jq -r '.whole_night[0].commands[0]')" \
    "the range runs from the older to the newer commit in history"
  assert_equals "$a $b" "$(printf '%s' "$out" | jq -r '.whole_night[0].commits | join(" ")')" "commits are oldest first in history"
  assert_equals 'https://github.com/o/r/pull/121' \
    "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 122) | [.revert_together[].url] | join(";")')" \
    "a same-second merge on the same file is still marked"
  pass "same-second merges use first-parent history order"
}

test_same_second_merges_list_the_later_decision_first() {
  local a b out
  new_case same-second-rows
  a=$(commit_on_dev a.txt 'older merge')
  b=$(commit_on_dev b.txt 'newer merge')
  # Same mergedAt second; the ledger glob reads the older 131 before the newer 132.
  merged_pr 131 1100 2026-11-27T02:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  merged_pr 132 1200 2026-11-27T02:00:00Z "$b" '["b.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "same-second rows --json exits 0"
  assert_equals '132 131' "$(printf '%s' "$out" | jq -r '[.merges[].number] | join(" ")')" \
    "the later merge decision is listed first"
  pass "same-second merges list the later decision first"
}

test_rebase_merged_multi_commit_pr_offers_no_whole_night_revert() {
  local a1 a2 s out
  new_case rebase-merge
  a1=$(commit_on_dev a.txt 'rebased commit one')
  a2=$(commit_on_dev b.txt 'rebased commit two')
  pr_diff 151 "$a1^" "$a2"
  MP_COMMITS=2 merged_pr 151 1100 2026-11-27T01:00:00Z "$a2" '["a.txt","b.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "rebase-merge --json exits 0"
  assert_equals unknown "$(printf '%s' "$out" | jq -r '.whole_night[0].status')" "a rebase-merged multi-commit PR gives no whole-night revert"
  assert_contains "$(printf '%s' "$out" | jq -r '.whole_night[0].reason')" 'https://github.com/o/r/pull/151' "the reason names the PR"
  assert_equals 0 "$(printf '%s' "$out" | jq -r '.whole_night[0].commands | length')" "no range is guessed"
  new_case squash-merge
  s=$(commit_on_dev a.txt 'squash of two commits')
  pr_diff 152 "$s^" "$s"
  MP_COMMITS=2 merged_pr 152 1100 2026-11-27T01:00:00Z "$s" '["a.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "squash-merge --json exits 0"
  assert_equals "git revert --no-edit $s^..$s" "$(printf '%s' "$out" | jq -r '.whole_night[0].commands[0]')" \
    "a squash of a multi-commit PR still gets the range revert"
  pass "a rebase-merged multi-commit PR offers no whole-night revert"
}

test_revert_together_stays_within_one_repository_and_base() {
  local a b c out
  new_case same-scope
  a=$(commit_on_dev shared.txt 'dev merge')
  b=$(commit_on_dev shared.txt 'release merge')
  c=$(commit_on_dev shared.txt 'other repo merge')
  merged_pr 161 1100 2026-11-27T01:00:00Z "$a" '["shared.txt"]' '[]' low "$NA_POST"
  MP_BASE=release merged_pr 162 1200 2026-11-27T02:00:00Z "$b" '["shared.txt"]' '[]' low "$NA_POST"
  MP_REPO=o/other merged_pr 163 1300 2026-11-27T03:00:00Z "$c" '["shared.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "same-scope --json exits 0"
  assert_equals 0 "$(printf '%s' "$out" | jq -r '[.merges[].revert_together[]] | length')" \
    "the same path on another base or in another repository is not a revert-together mark"
  pass "revert-together marks stay within one repository and base"
}

test_merge_at_an_unreviewed_head_shows_review_fields_unknown() {
  local a out
  new_case unmatched-head
  a=$(commit_on_dev a.txt 'merged at a head the ledger never reviewed')
  MP_HEAD=ffffffffffffffffffffffffffffffffffffffff merged_pr 171 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' high "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "unmatched-head --json exits 0"
  assert_equals 'unknown null null null' \
    "$(printf '%s' "$out" | jq -r '.merges[0] | "\(.review) \(.risk) \(.reviewers) \(.validation)"')" \
    "no other generation's risk, reviewers, or validation stand in"
  out=$(night --since 1000 --until 2000) || fail "unmatched-head text exits 0"
  assert_contains "$out" 'review: unknown' "the text marks the review unknown"
  assert_not_contains "$out" 'risk: high' "the unreviewed generation's risk is not shown"
  pass "a merge at an unreviewed head shows its review fields unknown"
}

test_row_uses_the_ledger_as_first_read() {
  local a out
  new_case concurrent
  a=$(commit_on_dev a.txt 'merge whose ledger changes mid-run')
  merged_pr 181 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  out=$(FM_TEST_MUTATE_LEDGER="$(ledger_of 181)" night --since 1000 --until 2000 --json) || fail "concurrent --json exits 0"
  assert_equals '1100 []' "$(printf '%s' "$out" | jq -c -j '.merges[0] | .decision_epoch, " ", .waiver')" \
    "the row keeps the merge decision from the read that admitted it"
  pass "the row uses the ledger as first read"
}

test_clone_origin_must_be_github_dot_com_exactly() {
  local a out
  new_case lookalike-host
  git -C "$CASE/home/projects/r" remote set-url origin https://evilgithub.com/o/r.git
  a=$(commit_on_dev a.txt 'merge with only a lookalike clone')
  merged_pr 191 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "lookalike-host --json exits 0"
  assert_equals unknown "$(printf '%s' "$out" | jq -r '.whole_night[0].status')" "a lookalike host is not the PR's clone"
  assert_contains "$(printf '%s' "$out" | jq -r '.whole_night[0].reason')" 'no local clone' "the reason says no clone matched"
  pass "the clone origin must be github.com exactly"
}

test_truncated_file_list_marks_overlap_incomplete() {
  local a b out
  new_case truncated-files
  a=$(commit_on_dev a.txt 'earlier merge')
  b=$(commit_on_dev b.txt 'merge past the forge file limit')
  merged_pr 201 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  MP_CHANGED=3001 merged_pr 202 1200 2026-11-27T02:00:00Z "$b" '["b.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "truncated --json exits 0"
  assert_equals 'false true' "$(printf '%s' "$out" | jq -r '[.merges[] | .files_complete] | map(tostring) | join(" ")')" \
    "the truncated file list is flagged"
  assert_equals 'https://github.com/o/r/pull/202' \
    "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 201) | .revert_together_incomplete | join(";")')" \
    "an earlier merge's overlap result names the truncated later merge"
  out=$(night --since 1000 --until 2000) || fail "truncated text exits 0"
  assert_contains "$out" 'revert together: incomplete' "the text says the overlap result is incomplete"
  pass "a truncated file list marks the overlap result incomplete"
}

test_malformed_merge_decision_is_listed_unreadable() {
  local a out ledger
  new_case malformed
  a=$(commit_on_dev a.txt 'merge with a malformed decision')
  merged_pr 211 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  ledger=$(ledger_of 211)
  jq '.generations[0].merge_decision.verified_epoch = "soon"' "$ledger" > "$ledger.new"
  mv "$ledger.new" "$ledger"
  out=$(night --since 1000 --until 2000 --json) || fail "malformed --json exits 0"
  assert_equals "$ledger" "$(printf '%s' "$out" | jq -r '.unreadable | join(";")')" "the malformed ledger is listed by path"
  pass "a malformed merge decision is listed unreadable"
}

test_renamed_file_marks_merges_on_its_old_path() {
  local a b out
  new_case rename
  a=$(commit_on_dev old.txt 'touch the old path')
  b=$(commit_on_dev new.txt 'rename old to new')
  merged_pr 221 1100 2026-11-27T01:00:00Z "$a" '["old.txt"]' '[]' low "$NA_POST"
  merged_pr 222 1200 2026-11-27T02:00:00Z "$b" '[{"path":"new.txt","previous":"old.txt"}]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "rename --json exits 0"
  assert_equals 'https://github.com/o/r/pull/222 old.txt' \
    "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 221) | .revert_together | map("\(.url) \(.files | join(","))") | join(";")')" \
    "a later rename away from the path is a revert-together mark"
  pass "a renamed file marks merges on its old path"
}

test_equal_second_merges_order_by_number_and_never_mark_each_other() {
  local a b out
  new_case exact-tie
  a=$(commit_on_dev shared.txt 'first of a tie')
  b=$(commit_on_dev shared.txt 'second of a tie')
  merged_pr 232 1100 2026-11-27T01:00:00Z "$b" '["shared.txt"]' '[]' low "$NA_POST"
  merged_pr 231 1100 2026-11-27T01:00:00Z "$a" '["shared.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --json) || fail "exact-tie --json exits 0"
  assert_equals '232 231' "$(printf '%s' "$out" | jq -r '[.merges[].number] | join(" ")')" "an exact tie orders by PR number, newest first"
  assert_equals 'https://github.com/o/r/pull/232' \
    "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 231) | [.revert_together[].url] | join(";")')" \
    "the earlier merge marks the later one"
  assert_equals 0 "$(printf '%s' "$out" | jq -r '.merges[] | select(.number == 232) | .revert_together | length')" \
    "the later merge does not mark the earlier one back"
  pass "equal-second merges order by number and never mark each other"
}

test_repo_filter_matches_the_repository_exactly() {
  local a b out
  new_case repo-filter
  a=$(commit_on_dev a.txt 'merge in o/r')
  b=$(commit_on_dev b.txt 'merge in o/r--x')
  merged_pr 241 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  MP_REPO=o/r--x merged_pr 242 1200 2026-11-27T02:00:00Z "$b" '["b.txt"]' '[]' low "$NA_POST"
  out=$(night --since 1000 --until 2000 --repo o/r --json) || fail "repo-filter --json exits 0"
  assert_equals 241 "$(printf '%s' "$out" | jq -r '[.merges[].number] | join(" ")')" "a neighbouring repository's ledger is not included"
  out=$(night --since 1000 --until 2000 --repo 'o/r*' 2>&1) && fail "a glob in --repo is refused"
  assert_contains "$out" 'owner/repo' "the refusal names the expected form"
  pass "the repo filter matches the repository exactly"
}

test_stalled_forge_call_stops_with_an_error_naming_the_pr() {
  local a out err status=0
  new_case stalled
  a=$(commit_on_dev a.txt 'merge whose forge read stalls')
  merged_pr 251 1100 2026-11-27T01:00:00Z "$a" '["a.txt"]' '[]' low "$NA_POST"
  out=$(FM_TEST_GH_STALL=251 FM_NIGHT_LEDGER_GH_TIMEOUT=1 night --since 1000 --until 2000 2>"$CASE/err") || status=$?
  err=$(cat "$CASE/err")
  assert_not_equals 0 "$status" "a stalled forge call fails the run"
  assert_equals '' "$out" "no partial ledger is printed"
  assert_contains "$err" 'https://github.com/o/r/pull/251' "the error names the PR"
  assert_contains "$err" 'timed out' "the error says the call timed out"
  pass "a stalled forge call stops with an error naming the PR"
}

fm_test_run \
  test_contiguous_window_lists_merges_newest_first_with_one_range_revert \
  test_non_contiguous_window_names_interleaved_commits \
  test_revert_together_marks_later_merges_touching_the_same_files \
  test_empty_window_reports_no_merges \
  test_missing_post_merge_data_is_reported_not_recorded \
  test_split_night_on_a_long_history_is_still_not_contiguous \
  test_merge_commit_night_offers_no_whole_night_revert \
  test_files_past_the_first_page_still_mark_revert_together \
  test_whole_night_is_unknown_without_a_merged_commit_or_origin_ref \
  test_cross_repo_closed_issue_reopens_in_its_own_repo \
  test_legacy_single_waiver_is_listed \
  test_same_second_merges_use_history_order \
  test_same_second_merges_list_the_later_decision_first \
  test_rebase_merged_multi_commit_pr_offers_no_whole_night_revert \
  test_revert_together_stays_within_one_repository_and_base \
  test_merge_at_an_unreviewed_head_shows_review_fields_unknown \
  test_row_uses_the_ledger_as_first_read \
  test_clone_origin_must_be_github_dot_com_exactly \
  test_truncated_file_list_marks_overlap_incomplete \
  test_malformed_merge_decision_is_listed_unreadable \
  test_renamed_file_marks_merges_on_its_old_path \
  test_equal_second_merges_order_by_number_and_never_mark_each_other \
  test_repo_filter_matches_the_repository_exactly \
  test_stalled_forge_call_stops_with_an_error_naming_the_pr
