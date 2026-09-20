#!/usr/bin/env bash
# Collect one coherent GitHub pull-request review snapshot as JSON.
# The head is read before and after every paginated review surface. A head move,
# pagination truncation, or unreadable surface refuses instead of producing a
# partial snapshot. The output includes top-level comments, submitted reviews,
# every inline review thread, requested reviewers, triggered reviewer checks,
# and required checks bound to the exact head.
#
# Usage: fm-pr-review-snapshot.sh <pr-url> <output.json>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY="$ROOT/.github/firstmate-review-policy.json"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { printf 'fm-pr-review-snapshot: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 2 ] || { echo 'usage: fm-pr-review-snapshot.sh <pr-url> <output.json>' >&2; exit 2; }
command -v gh >/dev/null 2>&1 || die 'gh is required for lossless machine-readable GitHub API responses'
command -v jq >/dev/null 2>&1 || die 'jq is required'
fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || die 'expected a GitHub pull-request URL'
[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || die 'review policy configuration is unavailable'

URL=$FM_PR_URL
PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
OUT=$2
OUT_DIR=$(dirname "$OUT")
[ -d "$OUT_DIR" ] && [ ! -L "$OUT_DIR" ] || die 'output directory is unavailable'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-review-snapshot.XXXXXX") || die 'could not create temporary directory'
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT HUP INT TERM

gh api "/repos/$PATH_PART/pulls/$NUMBER" > "$TMP/core.json" || die 'could not read pull-request state'
HEAD=$(jq -er '.head.sha | select(test("^[0-9a-fA-F]{40}$"))' "$TMP/core.json") || die 'pull-request head is unreadable'
AUTHOR=$(jq -er '.user.login | select(type == "string" and length > 0)' "$TMP/core.json") || die 'pull-request author is unreadable'
gh api "/repos/$PATH_PART/pulls/$NUMBER/files?per_page=100" --paginate --slurp > "$TMP/files-pages.json" || die 'could not read changed files'
gh api "/repos/$PATH_PART/issues/$NUMBER/comments?per_page=100" --paginate --slurp > "$TMP/top-pages.json" || die 'could not read top-level comments'
gh api "/repos/$PATH_PART/pulls/$NUMBER/reviews?per_page=100" --paginate --slurp > "$TMP/reviews-pages.json" || die 'could not read submitted reviews'
gh pr checks "$URL" --required --json name,state,bucket,link > "$TMP/required.json" 2> "$TMP/checks.err" || true
if jq -e 'type == "array"' "$TMP/required.json" >/dev/null 2>&1; then
  : # Pending and failed checks deliberately return nonzero with complete JSON.
elif grep -q "^no required checks reported on the '" "$TMP/checks.err"; then
  printf '[]\n' > "$TMP/required.json"
elif grep -q "^no checks reported on the '" "$TMP/checks.err"; then
  printf '[]\n' > "$TMP/required.json"
else
  cat "$TMP/checks.err" >&2
  die 'could not read required checks'
fi
gh pr view "$URL" --json headRefOid,statusCheckRollup > "$TMP/rollup.json" || die 'could not read triggered reviewer checks'

jq -n --arg owner "$OWNER" --arg repo "$REPO" --argjson number "$NUMBER" '{
  query:"query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){headRefOid reviewThreads(first:100){pageInfo{hasNextPage}nodes{id isResolved comments(first:100){pageInfo{hasNextPage}nodes{databaseId url body updatedAt author{login} commit{oid}}}}}}}}",
  variables:{owner:$owner,repo:$repo,number:$number}
}' > "$TMP/graphql-request.json"
gh api graphql --input "$TMP/graphql-request.json" > "$TMP/threads.json" || die 'could not read inline review threads'
jq -e '
  .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false and
  all(.data.repository.pullRequest.reviewThreads.nodes[]; .comments.pageInfo.hasNextPage == false)
' "$TMP/threads.json" >/dev/null || die 'inline review thread pagination exceeded the bounded complete read'

AFTER=$(gh pr view "$URL" --json headRefOid -q .headRefOid) || die 'could not re-read pull-request head'
[ "$AFTER" = "$HEAD" ] || die 'pull-request head changed during review collection; retry on the new head'
[ "$(jq -r .headRefOid "$TMP/rollup.json")" = "$HEAD" ] || die 'triggered checks were read from a different head'
[ "$(jq -r .data.repository.pullRequest.headRefOid "$TMP/threads.json")" = "$HEAD" ] || die 'inline threads were read from a different head'

jq -n \
  --arg url "$URL" --arg head "$HEAD" --arg author "$AUTHOR" \
  --slurpfile core "$TMP/core.json" \
  --slurpfile files "$TMP/files-pages.json" \
  --slurpfile top "$TMP/top-pages.json" \
  --slurpfile reviews "$TMP/reviews-pages.json" \
  --slurpfile threads "$TMP/threads.json" \
  --slurpfile required "$TMP/required.json" \
  --slurpfile rollup "$TMP/rollup.json" \
  --slurpfile policy "$POLICY" '
  def pages($x): ($x[0] | add // []);
  def external: select((.user.login // .author.login // "") != $author);
  def check_pending: (.status != "COMPLETED");
  ($policy[0].reviewer_check_name_patterns | map(ascii_downcase)) as $markers
  | ($rollup[0].statusCheckRollup // []) as $rollup_checks
  | {
      schema:"firstmate-pr-review-snapshot.v1",
      url:$url,
      head:$head,
      files:(pages($files) | map({filename,status,additions,deletions})),
      pending_reviews:(
        ([($core[0].requested_reviewers // [])[] | "user:" + .login]
         + [($core[0].requested_teams // [])[] | "team:" + .slug]
         + [$rollup_checks[]
            | select(check_pending)
            | (.name // .context // "") as $name
            | select(any($markers[]; . as $marker | ($name | ascii_downcase | contains($marker))))
            | "check:" + $name]) | unique),
      comments:(
        [pages($top)[] | external
          | {kind:"top-level",id:(.id|tostring),url:.html_url,author:.user.login,
             body:(.body // ""),updated_at:(.updated_at // .created_at),head:$head}]
        + [pages($reviews)[] | external
          | select((.body // "") != "" or .state == "CHANGES_REQUESTED")
          | {kind:"review-submission",id:(.id|tostring),url:.html_url,author:.user.login,
             body:(.body // ""),updated_at:.submitted_at,head:(.commit_id // "")}]
        + [$threads[0].data.repository.pullRequest.reviewThreads.nodes[]
          | select(any(.comments.nodes[]; (.author.login // "") != $author))
          | {kind:"inline-thread",id:.id,
             url:([.comments.nodes[] | select((.author.login // "") != $author) | .url] | first // $url),
             author:([.comments.nodes[] | select((.author.login // "") != $author) | .author.login] | unique | join(",")),
             body:([.comments.nodes[] | select((.author.login // "") != $author) | .body] | join("\n\n")),
             updated_at:([.comments.nodes[] | .updatedAt] | max),
             head:([.comments.nodes[] | .commit.oid // ""] | map(select(. != "")) | last // ""),
             resolved:.isResolved}]
        | unique_by([.kind,.id])),
      checks:($required[0] | map({name,state,bucket,url:.link,
        status:(if (.bucket == "pass" or .bucket == "skipping") then "COMPLETED" else .state end),
        conclusion:(.bucket // "unknown"),required:true}))
    }
  ' > "$TMP/snapshot.json" || die 'could not normalize review snapshot'

jq -e '
  .schema == "firstmate-pr-review-snapshot.v1" and
  (.head | test("^[0-9a-fA-F]{40}$")) and
  (.files | type == "array") and (.comments | type == "array") and
  (.pending_reviews | type == "array") and (.checks | type == "array")
' "$TMP/snapshot.json" >/dev/null || die 'normalized review snapshot is invalid'

STAGED=$(mktemp "$OUT_DIR/.fm-pr-review-snapshot.XXXXXX") || die 'could not stage review snapshot'
trap 'rm -f -- "$STAGED"; cleanup' EXIT HUP INT TERM
cp "$TMP/snapshot.json" "$STAGED"
chmod 0600 "$STAGED"
[ ! -e "$OUT" ] || { [ -f "$OUT" ] && [ ! -L "$OUT" ]; } || die 'output path is unsafe'
mv -f -- "$STAGED" "$OUT"
STAGED=
