#!/usr/bin/env bash
# Read-only night ledger: what merged in a time window and how to revert it.
#
# Usage:
#   fm-night-ledger.sh --since <epoch> [--until <epoch>] [--repo <owner/repo>] [--json]
#
# A merge is in the window when its GitHub review ledger
# (data/<ledger_directory>/github--OWNER--REPO--N.json under FM_HOME, the
# directory named by .github/firstmate-review-policy.json and written by
# bin/fm-pr-review.sh) holds a "merge" decision whose verified_epoch lies in
# [since, until]; --until defaults to now. The forge must also report the pull
# request merged; a recorded decision the forge does not report merged is listed
# under not_merged instead. A review ledger file that does not parse as
# firstmate-pr-review-ledger.v1 is listed under unreadable.
#
# Sources, all read-only: the review ledger (risk, reviewers, attestations,
# red-check waivers, post-merge record), `gh pr view` (title, base branch,
# merged time and commit, closing issues, changed files), and `git` on the
# local clone under FM_HOME/projects whose origin is the pull request's
# repository (first-parent history of refs/remotes/origin/<base>, else
# refs/heads/<base>). It never fetches, so contiguity reflects the clone's
# current refs. It writes nothing and never runs a revert.
#
# Text output lists one block per merge, newest first, then the whole-night
# revert per repository and base branch, then what a code revert does not undo.
#
# --json prints one object, schema "firstmate-night-ledger.v1":
#   since, until            window bounds (epochs)
#   repo                    the --repo filter, or null
#   merges[]                newest first by merged_epoch:
#     url, repo, number, title, base, merged_at (ISO), merged_epoch,
#     decision_epoch, merged_commit,
#     closed_issues[]       {number, url}
#     risk                  {level, reason} from the merged generation
#     reviewers[]           distinct review-item authors
#     validation[]          {kind, by, head}: no-mistakes model or reviewer actor
#     waiver[]              allowed red checks recorded on the merge decision
#     post_merge            {recorded:false} or {recorded:true, applicability,
#                           outcome, reason, bug}
#     files[]               paths the pull request changed
#     revert                "gh pr revert <url>"
#     revert_together[]     {url, files[]}: later in-window merges that touched
#                           any of the same files
#   whole_night[]           one per repo and base branch with merges:
#     repo, base, status    "contiguous", "not-contiguous", or "unknown"
#     commits[]             merged commits, oldest first
#     commands[]            when contiguous: one `git revert --no-edit
#                           <first>^..<last>`, or per-commit reverts newest
#                           first (`-m 1` for merge commits) when any merged
#                           commit has more than one parent
#     interleaved[]         when not contiguous: {sha, subject} of first-parent
#                           commits between the first and last merge that are
#                           not night merges
#     reason                why the status is unknown, else null
#   not_undone
#     closed_issues[]       {repo, number, url, reopen:"gh issue reopen <n> --repo <owner/repo>"}
#     notes[]               fixed reminders of what a revert leaves in place
#   not_merged[]            ledger URLs with an in-window decision but no forge merge
#   unreadable[]            ledger file names that could not be parsed
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="$FM_HOME/projects"
POLICY="$ROOT/.github/firstmate-review-policy.json"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { printf 'fm-night-ledger: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }

SINCE='' UNTIL='' REPO='' JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since) [ "$#" -ge 2 ] || die '--since needs an epoch'; SINCE=$2; shift 2 ;;
    --until) [ "$#" -ge 2 ] || die '--until needs an epoch'; UNTIL=$2; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || die '--repo needs owner/repo'; REPO=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$SINCE" in ''|*[!0-9]*) die '--since must be an epoch in seconds' ;; esac
[ -n "$UNTIL" ] || UNTIL=$(date -u +%s)
case "$UNTIL" in *[!0-9]*) die '--until must be an epoch in seconds' ;; esac
[ "$UNTIL" -ge "$SINCE" ] || die '--until is before --since'
if [ -n "$REPO" ]; then
  [[ $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die '--repo must be owner/repo'
fi
for tool in jq gh git; do
  type -P "$tool" >/dev/null || die "$tool is required"
done
LEDGER_REL=$(jq -er '.ledger_directory | select(type == "string" and length > 0)' "$POLICY") \
  || die 'review ledger directory configuration is invalid'
case "$LEDGER_REL" in
  /*|.|..|*/../*|../*|*/..|*//*|*[!A-Za-z0-9._/-]*) die 'review ledger directory configuration is unsafe' ;;
esac
LEDGER_DIR="$DATA/$LEDGER_REL"

repo_slug() { # <remote-url> -> owner/repo for a GitHub remote, else empty
  printf '%s' "$1" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p' | sed 's#\.git$##'
}

clone_for() { # <owner/repo> -> local clone path
  local dir origin
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
    [ "$(repo_slug "$origin")" = "$1" ] && { printf '%s\n' "${dir%/}"; return 0; }
  done
  return 1
}

MERGES='[]' NOT_MERGED='[]' UNREADABLE='[]'
prefix=github--
[ -z "$REPO" ] || prefix="github--${REPO%%/*}--${REPO#*/}--"
for file in "$LEDGER_DIR/$prefix"*.json; do
  [ -e "$file" ] || continue
  name=${file##*/}
  if ! [ -f "$file" ] || [ -L "$file" ] || ! url=$(jq -er '
      select(.schema == "firstmate-pr-review-ledger.v1" and (.generations | type == "array"))
      | .url | strings' "$file" 2>/dev/null); then
    UNREADABLE=$(jq -c --arg f "$name" '. + [$f]' <<<"$UNREADABLE")
    continue
  fi
  jq -e --argjson since "$SINCE" --argjson until "$UNTIL" '
    [.generations[] | select(.merge_decision.decision? == "merge")] | last
    | .merge_decision.verified_epoch | numbers | . >= $since and . <= $until' "$file" >/dev/null 2>&1 || continue
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || {
    UNREADABLE=$(jq -c --arg f "$name" '. + [$f]' <<<"$UNREADABLE"); continue; }
  forge=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh pr view "$FM_PR_URL" \
    --json title,state,mergedAt,mergeCommit,baseRefName,closingIssuesReferences,files) \
    || die "gh could not read $FM_PR_URL"
  if [ "$(jq -r '.state' <<<"$forge")" != MERGED ]; then
    NOT_MERGED=$(jq -c --arg u "$FM_PR_URL" '. + [$u]' <<<"$NOT_MERGED")
    continue
  fi
  row=$(jq -c --argjson gh "$forge" --arg repo "$FM_PR_OWNER/$FM_PR_REPO" \
    --argjson number "$FM_PR_NUMBER" --arg url "$FM_PR_URL" '
    ([.generations[] | select(.merge_decision.decision? == "merge")] | last) as $g
    | (($g.post_merge_verifications // []) | last) as $pm
    | {url:$url, repo:$repo, number:$number, title:$gh.title, base:$gh.baseRefName,
       merged_at:$gh.mergedAt, merged_epoch:($gh.mergedAt | fromdateiso8601),
       decision_epoch:$g.merge_decision.verified_epoch,
       merged_commit:($gh.mergeCommit.oid // $pm.forge_merge_sha),
       closed_issues:[$gh.closingIssuesReferences[]? | {number, url}],
       risk:($g.risk // {level:null, reason:null}),
       reviewers:([$g.review_items[]?.author | strings] | unique),
       validation:[$g.attestations[]? | {kind, by:(.model // .actor), head}],
       waiver:($g.merge_decision.allowed_red_checks // []),
       post_merge:(if $pm == null then {recorded:false}
         else {recorded:true, applicability:$pm.applicability, outcome:$pm.outcome,
           reason:$pm.reason, bug:$pm.bug.url?} end),
       files:[$gh.files[]?.path],
       revert:("gh pr revert " + $url)}' "$file")
  MERGES=$(jq -c --argjson r "$row" '. + [$r]' <<<"$MERGES")
done

MERGES=$(jq -c '
  sort_by(-.merged_epoch)
  | . as $all
  | map(. as $m | .revert_together = [$all[]
      | select(.merged_epoch > $m.merged_epoch)
      | {url, files:([.files[] | select(IN($m.files[]; .))] | unique)}
      | select(.files | length > 0)])' <<<"$MERGES")

whole_night_group() { # <repo> <base> <commits-json oldest first>
  local repo=$1 base=$2 commits=$3 clone ref history sha parents merge_commit=0 cmds interleaved='[]'
  local base_json
  base_json=$(jq -cn --arg repo "$repo" --arg base "$base" --argjson c "$commits" \
    '{repo:$repo, base:$base, commits:$c, commands:[], interleaved:[], reason:null}')
  if ! clone=$(clone_for "$repo"); then
    jq -c --arg r "no local clone of $repo under $PROJECTS" '.status = "unknown" | .reason = $r' <<<"$base_json"
    return
  fi
  ref=
  for candidate in "refs/remotes/origin/$base" "refs/heads/$base"; do
    if git -C "$clone" rev-parse -q --verify "$candidate^{commit}" >/dev/null 2>&1; then ref=$candidate; break; fi
  done
  if [ -z "$ref" ]; then
    jq -c --arg r "the clone has no $base branch ref" '.status = "unknown" | .reason = $r' <<<"$base_json"
    return
  fi
  history=$(git -C "$clone" rev-list --first-parent "$ref" | jq -Rsc 'split("\n") | map(select(length > 0))')
  result=$(jq -c --argjson h "$history" --argjson c "$commits" '
    [$c[] as $s | ($h | index($s))] as $pos
    | if any($pos[]; . == null) then
        {missing:[range(0; $c | length) as $i | select($pos[$i] == null) | $c[$i]]}
      else
        ($pos | min) as $lo | ($pos | max) as $hi
        | {interleaved:[$h[$lo:$hi + 1][] | select(. as $s | $c | index($s) | not)]}
      end' <<<'null')
  if jq -e 'has("missing")' <<<"$result" >/dev/null; then
    jq -c --arg r "merged commit(s) $(jq -r '.missing | join(" ")' <<<"$result") not on $ref; fetch the clone and rerun" \
      '.status = "unknown" | .reason = $r' <<<"$base_json"
    return
  fi
  for sha in $(jq -r '.interleaved[]' <<<"$result"); do
    interleaved=$(jq -c --arg s "$sha" --arg subj "$(git -C "$clone" log -1 --format=%s "$sha")" \
      '. + [{sha:$s, subject:$subj}]' <<<"$interleaved")
  done
  if [ "$interleaved" != '[]' ]; then
    jq -c --argjson i "$interleaved" '.status = "not-contiguous" | .interleaved = $i' <<<"$base_json"
    return
  fi
  cmds='[]'
  for sha in $(jq -r 'reverse[]' <<<"$commits"); do
    parents=$(git -C "$clone" rev-list --parents -n 1 "$sha" | wc -w)
    if [ "$parents" -gt 2 ]; then
      merge_commit=1
      cmds=$(jq -c --arg c "git revert --no-edit -m 1 $sha" '. + [$c]' <<<"$cmds")
    else
      cmds=$(jq -c --arg c "git revert --no-edit $sha" '. + [$c]' <<<"$cmds")
    fi
  done
  [ "$merge_commit" -eq 1 ] || cmds=$(jq -c --argjson c "$commits" '[("git revert --no-edit " + $c[0] + "^.." + $c[-1])]' <<<'null')
  jq -c --argjson cmds "$cmds" '.status = "contiguous" | .commands = $cmds' <<<"$base_json"
}

WHOLE='[]'
while IFS=$'\t' read -r repo base commits; do
  [ -n "$repo" ] || continue
  WHOLE=$(jq -c --argjson g "$(whole_night_group "$repo" "$base" "$commits")" '. + [$g]' <<<"$WHOLE")
done < <(jq -r 'group_by([.repo, .base])[]
  | [.[0].repo, .[0].base, (sort_by(.merged_epoch) | map(.merged_commit) | tojson)] | @tsv' <<<"$MERGES")

OUT=$(jq -n --argjson since "$SINCE" --argjson until "$UNTIL" --arg repo "$REPO" \
  --argjson merges "$MERGES" --argjson whole "$WHOLE" \
  --argjson not_merged "$NOT_MERGED" --argjson unreadable "$UNREADABLE" '{
    schema:"firstmate-night-ledger.v1", since:$since, until:$until,
    repo:(if $repo == "" then null else $repo end),
    merges:$merges, whole_night:$whole,
    not_undone:{
      closed_issues:[$merges[] as $m | $m.closed_issues[]
        | {repo:$m.repo, number, url, reopen:("gh issue reopen \(.number) --repo \($m.repo)")}],
      notes:["Issues and comments filed overnight are not reverted by a code revert.",
        "Closed issues stay closed until reopened."]},
    not_merged:$not_merged, unreadable:$unreadable}')

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$OUT"
  exit 0
fi

jq -r '
  def iso: todate;
  def post: if .recorded | not then "not recorded"
    else ([.applicability, .outcome] | map(select(. != null)) | join(" "))
      + (if .reason then " (" + .reason + ")" else "" end)
      + (if .bug then " bug " + .bug else "" end) end;
  "Night ledger \(.since | iso) .. \(.until | iso)\(if .repo then " for " + .repo else "" end): \(.merges | length) merge(s)",
  "",
  (if (.merges | length) == 0 then "No merges recorded in this window.", "" else empty end),
  (.merges[] |
    "\(.url)  \(.title)",
    "  merged: \(.merged_at) into \(.base) as \(.merged_commit)",
    "  closed issues: \(if (.closed_issues | length) == 0 then "none" else (.closed_issues | map("#\(.number)") | join(" ")) end)",
    "  risk: \(.risk.level // "unknown")\(if .risk.reason then " (" + .risk.reason + ")" else "" end)",
    "  reviewers: \(if (.reviewers | length) == 0 then "none recorded" else (.reviewers | join(", ")) end)",
    "  validation: \(if (.validation | length) == 0 then "none recorded" else (.validation | map("\(.kind) \(.by)") | join(", ")) end)",
    "  waiver: \(if (.waiver | length) == 0 then "none" else (.waiver | join(", ")) end)",
    "  post-merge: \(.post_merge | post)",
    "  revert: \(.revert)",
    (.revert_together[] | "  revert together with: \(.url) (shared: \(.files | join(", ")))"),
    ""),
  (if (.whole_night | length) > 0 then "Whole-night revert:" else empty end),
  (.whole_night[] |
    if .status == "contiguous" then
      "  \(.repo) \(.base): contiguous on first-parent history (\(.commits | length) commit(s))",
      (.commands[] | "    " + .)
    elif .status == "not-contiguous" then
      "  \(.repo) \(.base): not contiguous; no single range revert. Interleaved commits:",
      (.interleaved[] | "    \(.sha) \(.subject)"),
      "  Revert each merge newest first with its own command instead."
    else "  \(.repo) \(.base): contiguity unknown - \(.reason)" end),
  (if (.whole_night | length) > 0 then "" else empty end),
  "What a code revert does not undo:",
  (.not_undone.closed_issues[] | "  \(.reopen)   # \(.url)"),
  (.not_undone.notes[] | "  " + .),
  (if (.not_merged | length) > 0 then "", "Merge decision recorded but not merged on the forge:", (.not_merged[] | "  " + .) else empty end),
  (if (.unreadable | length) > 0 then "", "Unreadable review ledger files:", (.unreadable[] | "  " + .) else empty end)
' <<<"$OUT"
