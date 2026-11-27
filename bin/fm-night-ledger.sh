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
# merged time and commit, closing issues), `gh api --paginate` (every changed
# file), and `git` on the local clone under FM_HOME/projects whose origin is the
# pull request's repository (first-parent history of refs/remotes/origin/<base>).
# It never fetches, so contiguity reflects the clone's current refs. It writes
# nothing and never runs a revert.
#
# Text output lists one block per merge, newest first, then the whole-night
# revert per repository and base branch, then what a code revert does not undo.
#
# --json prints one object, schema "firstmate-night-ledger.v1":
#   since, until            window bounds (epochs)
#   repo                    the --repo filter, or null
#   merges[]                newest first by merged_epoch, then decision_epoch:
#     url, repo, number, title, base, merged_at (ISO), merged_epoch,
#     decision_epoch, merged_commit (null when the forge reports none),
#     closed_issues[]       {repo, number, url}: repo is the issue's own repository
#     risk                  {level, reason} from the merged generation
#     reviewers[]           distinct review-item authors
#     validation[]          {kind, by, head}: no-mistakes model or reviewer actor
#     waiver[]              allowed red checks recorded on the merge decision
#                           (allowed_red_checks, else a legacy allowed_red_check)
#     post_merge            {recorded:false} or {recorded:true, applicability,
#                           outcome, reason, bug}
#     files[]               paths the pull request changed
#     revert                "gh pr revert <url>"
#     revert_together[]     {url, files[]}: later (or same-second) in-window merges that touched
#                           any of the same files
#   whole_night[]           one per repo and base branch with merges:
#     repo, base, status    "contiguous", "not-contiguous", or "unknown"
#     commits[]             merged commits, oldest first (by first-parent
#                           position once found on the ref, else by merged time)
#     commands[]            when contiguous: one `git revert --no-edit
#                           <first>^..<last>`
#     interleaved[]         when not contiguous: {sha, subject} of first-parent
#                           commits between the first and last merge that are
#                           not night merges
#     reason                why the status is unknown (including a merged
#                           commit with more than one parent), else null
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

ROWS='' NOT_MERGED='[]' UNREADABLE='[]'
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
    --json title,state,mergedAt,mergeCommit,baseRefName,closingIssuesReferences) \
    || die "gh could not read $FM_PR_URL"
  if [ "$(jq -r '.state' <<<"$forge")" != MERGED ]; then
    NOT_MERGED=$(jq -c --arg u "$FM_PR_URL" '. + [$u]' <<<"$NOT_MERGED")
    continue
  fi
  paths=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh api --hostname "$FM_PR_HOST" --paginate \
    "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER/files?per_page=100" --jq '.[].filename') \
    || die "gh could not list the files of $FM_PR_URL"
  row=$(jq -Rsc --slurpfile ledger "$file" --argjson gh "$forge" --arg repo "$FM_PR_OWNER/$FM_PR_REPO" \
    --argjson number "$FM_PR_NUMBER" --arg url "$FM_PR_URL" '
    (split("\n") | map(select(length > 0))) as $files
    | $ledger[0]
    | ([.generations[] | select(.merge_decision.decision? == "merge")] | last) as $g
    | (($g.post_merge_verifications // []) | last) as $pm
    | {url:$url, repo:$repo, number:$number, title:$gh.title, base:$gh.baseRefName,
       merged_at:$gh.mergedAt, merged_epoch:($gh.mergedAt | fromdateiso8601),
       decision_epoch:$g.merge_decision.verified_epoch,
       merged_commit:$gh.mergeCommit.oid,
       closed_issues:[$gh.closingIssuesReferences[]? | {repo:(.repository.owner.login + "/" + .repository.name), number, url}],
       risk:($g.risk // {level:null, reason:null}),
       reviewers:([$g.review_items[]?.author | strings] | unique),
       validation:[$g.attestations[]? | {kind, by:(.model // .actor), head}],
       waiver:($g.merge_decision.allowed_red_checks // [$g.merge_decision.allowed_red_check | strings]),
       post_merge:(if $pm == null then {recorded:false}
         else {recorded:true, applicability:$pm.applicability, outcome:$pm.outcome,
           reason:$pm.reason, bug:$pm.bug.url?} end),
       files:$files,
       revert:("gh pr revert " + $url)}' <<<"$paths")
  ROWS+=$row$'\n'
done

MERGES=$(jq -sc '
  sort_by(-.merged_epoch, -.decision_epoch)
  | . as $all
  | map(. as $m | .revert_together = [$all[]
      | select(.merged_epoch >= $m.merged_epoch and .url != $m.url)
      | {url, files:([.files[] | select(IN($m.files[]; .))] | unique)}
      | select(.files | length > 0)])' <<<"$ROWS")

whole_unknown() { # <group-json> <reason>
  jq -c --arg r "$2" '.status = "unknown" | .reason = $r' <<<"$1"
}

whole_night_group() { # <repo> <base> <commits-json oldest first>
  local repo=$1 base=$2 commits=$3 ref="refs/remotes/origin/$2" clone history result group
  group=$(jq -cn --arg repo "$repo" --arg base "$base" --argjson c "$commits" \
    '{repo:$repo, base:$base, commits:$c, commands:[], interleaved:[], reason:null}')
  if jq -e 'any(.[]; . == null)' <<<"$commits" >/dev/null; then
    whole_unknown "$group" "the forge reported no merged commit for at least one merge"
    return
  fi
  if ! clone=$(clone_for "$repo"); then
    whole_unknown "$group" "no local clone of $repo under $PROJECTS"
    return
  fi
  if ! git -C "$clone" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
    whole_unknown "$group" "the clone has no $ref"
    return
  fi
  if ! history=$(git -C "$clone" log --first-parent --format='%H%x09%P%x09%s' "$ref"); then
    whole_unknown "$group" "git could not read the first-parent history of $ref"
    return
  fi
  if ! result=$(jq -Rsc --argjson c "$commits" '
      split("\n") | map(select(length > 0) | split("\t")
        | {sha:.[0], parents:(.[1] | split(" ")), subject:(.[2:] | join("\t"))}) as $h
      | ($h | map(.sha)) as $shas
      | [$c[] as $s | ($shas | index($s))] as $pos
      | if any($pos[]; . == null) then
          {missing:[range(0; $c | length) as $i | select($pos[$i] == null) | $c[$i]]}
        else
          ($pos | min) as $lo | ($pos | max) as $hi
          | {commits:[$pos | sort | reverse[] | $h[.].sha],
             interleaved:[$h[$lo:$hi + 1][] | select(.sha as $s | $c | index($s) | not) | {sha, subject}],
             merges:[$pos[] as $p | $h[$p] | select(.parents | length > 1) | .sha]}
        end' <<<"$history"); then
    whole_unknown "$group" "could not compare the merged commits with the history of $ref"
    return
  fi
  if jq -e 'has("missing")' <<<"$result" >/dev/null; then
    whole_unknown "$group" "merged commit(s) $(jq -r '.missing | join(" ")' <<<"$result") not on $ref; fetch the clone and rerun"
    return
  fi
  group=$(jq -c --argjson g "$group" '.commits as $c | $g | .commits = $c' <<<"$result")
  if jq -e '.interleaved | length > 0' <<<"$result" >/dev/null; then
    jq -c --argjson g "$group" '.interleaved as $i | $g | .status = "not-contiguous" | .interleaved = $i' <<<"$result"
    return
  fi
  if jq -e '.merges | length > 0' <<<"$result" >/dev/null; then
    whole_unknown "$group" "merged commit(s) $(jq -r '.merges | join(" ")' <<<"$result") have more than one parent; no single range revert"
    return
  fi
  jq -c '.status = "contiguous" | .commands = ["git revert --no-edit " + .commits[0] + "^.." + .commits[-1]]' <<<"$group"
}

WHOLE_ROWS=''
while IFS=$'\t' read -r repo base commits; do
  [ -n "$repo" ] || continue
  WHOLE_ROWS+=$(whole_night_group "$repo" "$base" "$commits")$'\n'
done < <(jq -r 'group_by([.repo, .base])[]
  | [.[0].repo, .[0].base, (sort_by(.merged_epoch, .decision_epoch) | map(.merged_commit) | tojson)] | @tsv' <<<"$MERGES")

OUT=$({ printf '%s\n' "$MERGES"; jq -sc . <<<"$WHOLE_ROWS"; } | jq -n --argjson since "$SINCE" --argjson until "$UNTIL" --arg repo "$REPO" \
  --argjson not_merged "$NOT_MERGED" --argjson unreadable "$UNREADABLE" '
  input as $merges | input as $whole | {
    schema:"firstmate-night-ledger.v1", since:$since, until:$until,
    repo:(if $repo == "" then null else $repo end),
    merges:$merges, whole_night:$whole,
    not_undone:{
      closed_issues:[$merges[].closed_issues[]
        | {repo, number, url, reopen:("gh issue reopen \(.number) --repo \(.repo)")}],
      notes:["Issues and comments filed overnight are not reverted by a code revert.",
        "Closed issues stay closed until reopened.",
        "Test data written to the disposable dev app is not removed by a code revert."]},
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
    "  merged: \(.merged_at) into \(.base) as \(.merged_commit // "unknown")",
    "  closed issues: \(if (.closed_issues | length) == 0 then "none" else (.repo as $r | .closed_issues | map(if .repo == $r then "#\(.number)" else "\(.repo)#\(.number)" end) | join(" ")) end)",
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
    else "  \(.repo) \(.base): no whole-night revert - \(.reason)" end),
  (if (.whole_night | length) > 0 then "" else empty end),
  "What a code revert does not undo:",
  (.not_undone.closed_issues[] | "  \(.reopen)   # \(.url)"),
  (.not_undone.notes[] | "  " + .),
  (if (.not_merged | length) > 0 then "", "Merge decision recorded but not merged on the forge:", (.not_merged[] | "  " + .) else empty end),
  (if (.unreadable | length) > 0 then "", "Unreadable review ledger files:", (.unreadable[] | "  " + .) else empty end)
' <<<"$OUT"
