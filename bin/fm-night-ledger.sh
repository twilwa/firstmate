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
# [since, until]; --until defaults to now. --repo must be owner/repo and selects
# ledgers whose pull-request URL names exactly that repository. Each ledger file
# is read once, and both the window check and its row come from that read.
#
# The forge must report the pull request merged; a recorded decision the forge
# does not report merged is listed under not_merged instead. Review fields come
# only from the ledger generation whose head is the forge's merged head; a merge
# decision on that generation must itself lie in the window. When no generation
# has that head, the merge is still listed, with review "unknown" and its review
# fields null. A ledger file that is not a firstmate-pr-review-ledger.v1 object
# with well-formed generations and merge decisions is listed under unreadable.
#
# Sources, all read-only: the review ledger (risk, reviewers, attestations,
# red-check waivers, post-merge record), `gh pr view` (title, base branch,
# merged head, time and commit, commits, closing issues, changed-file count),
# `gh api --paginate` (every changed file and a renamed file's previous path),
# `gh pr diff` (only for a pull request with more than one commit), and `git` on
# the local clone under FM_HOME/projects whose origin is exactly
# github.com/<owner>/<repo> (first-parent history of refs/remotes/origin/<base>).
# It never fetches, so contiguity reflects the clone's current refs. It writes
# nothing and never runs a revert. Each gh call is bounded by
# FM_NIGHT_LEDGER_GH_TIMEOUT seconds (default 60); a call that hits the bound
# stops the run with an error naming the pull request and prints no ledger.
#
# Text output lists one block per merge, newest first, then the whole-night
# revert per repository and base branch, then what a code revert does not undo.
#
# --json prints one object, schema "firstmate-night-ledger.v1":
#   since, until            window bounds (epochs)
#   repo                    the --repo filter, or null
#   merges[]                newest first by merged_epoch, then decision_epoch,
#                           then PR number:
#     url, repo, number, title, base, merged_at (ISO), merged_epoch,
#     merged_head, commit_count,
#     decision_epoch        null when the merged generation has no merge decision
#     merged_commit         null when the forge reports none
#     closed_issues[]       {repo, number, url}: repo is the issue's own repository
#     review                "matched", or "unknown" when no ledger generation has
#                           the merged head (then risk, reviewers, validation,
#                           waiver, and post_merge are null)
#     risk                  {level, reason} from the merged generation
#     reviewers[]           distinct review-item authors
#     validation[]          {kind, by, head}: no-mistakes model or reviewer actor
#     waiver[]              allowed red checks recorded on the merge decision
#                           (allowed_red_checks, else a legacy allowed_red_check)
#     post_merge            {recorded:false} or {recorded:true, applicability,
#                           outcome, reason, bug}
#     files[]               paths the pull request changed, plus renamed files'
#                           previous paths
#     files_complete        false when the forge listed fewer files than it
#                           reports changed (its file listing is capped)
#     revert                "gh pr revert <url>"
#     revert_together[]     {url, files[]}: later in-window merges into the same
#                           repository and base that touched any of the same files
#     revert_together_incomplete[]
#                           URLs of this merge and those later same-scope merges
#                           whose file lists are incomplete
#   whole_night[]           one per repo and base branch with merges:
#     repo, base, status    "contiguous", "not-contiguous", or "unknown"
#     commits[]             merged commits, oldest first (by first-parent
#                           position once found on the ref, else by merge order)
#     commands[]            when contiguous: one `git revert --no-edit
#                           <first>^..<last>`
#     interleaved[]         when not contiguous: {sha, subject} of first-parent
#                           commits between the first and last merge that are
#                           not night merges
#     reason                why the status is unknown, else null. Unknown covers
#                           a missing merged commit or clone or ref, a merged
#                           commit with more than one parent, and a pull request
#                           with more than one commit whose merged commit's diff
#                           is not its whole diff (a rebase merge, judged by
#                           `git patch-id --stable`)
#   not_undone
#     closed_issues[]       {repo, number, url, reopen:"gh issue reopen <n> --repo <owner/repo>"}
#     notes[]               fixed reminders of what a revert leaves in place
#   not_merged[]            ledger URLs with an in-window decision but no forge merge
#   unreadable[]            paths of ledger files that could not be used
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

GH_TIMEOUT=${FM_NIGHT_LEDGER_GH_TIMEOUT:-60}
case "$GH_TIMEOUT" in ''|*[!0-9]*|0) die 'FM_NIGHT_LEDGER_GH_TIMEOUT must be a positive integer of seconds' ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

forge() { # <pr-url> <what> <gh args...>: bounded gh call; nonzero 124 on timeout
  local url=$1 what=$2 status=0
  shift 2
  fm_run_timed "$GH_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@" || status=$?
  if [ "$status" -ne 0 ] && fm_timed_out "$status"; then
    printf 'fm-night-ledger: gh timed out after %ss reading the %s of %s; no ledger printed\n' \
      "$GH_TIMEOUT" "$what" "$url" >&2
    return 124
  fi
  return "$status"
}

origin_slug() { # <remote-url> -> lowercase owner/repo when the remote is on github.com exactly
  local rest
  case "$1" in
    https://github.com/*) rest=${1#https://github.com/} ;;
    ssh://git@github.com/*) rest=${1#ssh://git@github.com/} ;;
    git@github.com:*) rest=${1#git@github.com:} ;;
    *) return 1 ;;
  esac
  rest=${rest%/}
  rest=${rest%.git}
  [[ $rest =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s\n' "${rest,,}"
}

clone_for() { # <owner/repo> -> local clone path under PROJECTS
  local dir origin slug
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
    slug=$(origin_slug "$origin") || continue
    [ "$slug" = "${1,,}" ] && { printf '%s\n' "${dir%/}"; return 0; }
  done
  return 1
}

VALID_LEDGER='
  select(type == "object" and .schema == "firstmate-pr-review-ledger.v1"
    and (.url | type == "string")
    and (.generations | type == "array" and length > 0 and all(.[];
      type == "object" and (.head | type == "string")
      and (.merge_decision == null or (.merge_decision | type == "object"
        and (if .decision == "merge" then (.verified_epoch | type == "number") else true end))))))
  | .url'

ROWS='' NOT_MERGED='[]' UNREADABLE='[]'
unreadable() { UNREADABLE=$(jq -c --arg f "$1" '. + [$f]' <<<"$UNREADABLE"); }
for file in "$LEDGER_DIR"/github--*.json; do
  [ -e "$file" ] || [ -L "$file" ] || continue
  ledger='' url=''
  if ! [ -f "$file" ] || [ -L "$file" ] || ! ledger=$(cat -- "$file" 2>/dev/null) \
    || ! url=$(jq -er "$VALID_LEDGER" <<<"$ledger" 2>/dev/null) \
    || ! fm_pr_url_parse "$url" || [ "$FM_PR_PROVIDER" != github ]; then
    unreadable "$file"
    continue
  fi
  [ -z "$REPO" ] || [ "${FM_PR_OWNER,,}/${FM_PR_REPO,,}" = "${REPO,,}" ] || continue
  jq -e --argjson since "$SINCE" --argjson until "$UNTIL" '
    any(.generations[]; .merge_decision.decision? == "merge"
      and .merge_decision.verified_epoch >= $since and .merge_decision.verified_epoch <= $until)' \
    <<<"$ledger" >/dev/null || continue
  pr=$(forge "$FM_PR_URL" 'pull request' pr view "$FM_PR_URL" \
    --json title,state,mergedAt,mergeCommit,baseRefName,headRefOid,commits,closingIssuesReferences,changedFiles) \
    || { [ "$?" -ne 124 ] || exit 1; die "gh could not read $FM_PR_URL"; }
  if [ "$(jq -r '.state' <<<"$pr")" != MERGED ]; then
    NOT_MERGED=$(jq -c --arg u "$FM_PR_URL" '. + [$u]' <<<"$NOT_MERGED")
    continue
  fi
  files=$(forge "$FM_PR_URL" 'changed files' api --hostname "$FM_PR_HOST" --paginate \
    "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER/files?per_page=100" \
    --jq '.[] | {filename, previous_filename}') \
    || { [ "$?" -ne 124 ] || exit 1; die "gh could not list the files of $FM_PR_URL"; }
  patch_id=''
  if [ "$(jq '.commits | length' <<<"$pr")" -gt 1 ]; then
    if diff=$(forge "$FM_PR_URL" diff pr diff "$FM_PR_URL"); then
      patch_id=$(printf '%s\n' "$diff" | git patch-id --stable | cut -d' ' -f1)
    else
      [ "$?" -ne 124 ] || exit 1
    fi
  fi
  ROWS+=$({ printf '%s\n%s\n' "$ledger" "$pr"; jq -sc . <<<"$files"; } | jq -nc \
    --arg repo "$FM_PR_OWNER/$FM_PR_REPO" --arg host "$FM_PR_HOST" --argjson number "$FM_PR_NUMBER" \
    --arg url "$FM_PR_URL" --arg patch "$patch_id" --argjson since "$SINCE" --argjson until "$UNTIL" '
    input as $L | input as $gh | input as $F
    | ([$L.generations[] | select(.head == $gh.headRefOid)] | last) as $g
    | ($g != null) as $matched
    | (if $matched and $g.merge_decision.decision? == "merge" then $g.merge_decision else null end) as $d
    | select($d == null or ($d.verified_epoch >= $since and $d.verified_epoch <= $until))
    | (if $matched then (($g.post_merge_verifications // []) | last) else null end) as $pm
    | {url:$url, repo:$repo, number:$number, title:$gh.title, base:$gh.baseRefName,
       merged_at:$gh.mergedAt, merged_epoch:($gh.mergedAt | fromdateiso8601),
       merged_head:$gh.headRefOid, commit_count:($gh.commits | length),
       decision_epoch:$d.verified_epoch,
       merged_commit:$gh.mergeCommit.oid,
       closed_issues:[$gh.closingIssuesReferences[]? | {repo:(.repository.owner.login + "/" + .repository.name), number, url}],
       review:(if $matched then "matched" else "unknown" end),
       risk:(if $matched then ($g.risk // {level:null, reason:null}) else null end),
       reviewers:(if $matched then ([$g.review_items[]?.author | strings] | unique) else null end),
       validation:(if $matched then [$g.attestations[]? | {kind, by:(.model // .actor), head}] else null end),
       waiver:(if $d == null then null else ($d.allowed_red_checks // [$d.allowed_red_check | strings]) end),
       post_merge:(if $matched | not then null elif $pm == null then {recorded:false}
         else {recorded:true, applicability:$pm.applicability, outcome:$pm.outcome,
           reason:$pm.reason, bug:$pm.bug.url?} end),
       files:([$F[] | .filename, (.previous_filename // empty)] | unique),
       files_complete:(($F | length) >= ($gh.changedFiles // 0)),
       revert:("gh pr revert " + $url),
       _host:$host, _patch:(if $patch == "" then null else $patch end)}')$'\n'
done

MERGES=$(jq -sc '
  sort_by(.merged_epoch, (.decision_epoch // -1), .number) | reverse
  | . as $all
  | [range(0; length) as $i | $all[$i] as $m
    | ($all[0:$i] | map(select(.repo == $m.repo and .base == $m.base))) as $later
    | $m + {revert_together:[$later[]
          | {url, files:([.files[] | select(IN($m.files[]; .))] | unique)}
          | select(.files | length > 0)],
        revert_together_incomplete:[([$m] + $later)[] | select(.files_complete | not) | .url]}]' <<<"$ROWS")

whole_unknown() { # <group-json> <reason>
  jq -c --arg r "$2" '.status = "unknown" | .reason = $r' <<<"$1"
}

whole_night_group() { # <repo> <base> <merges-json oldest first: {sha, url, commits, patch, host}>
  local repo=$1 base=$2 merges=$3 ref="refs/remotes/origin/$2" commits clone history result group
  local sha url local_patch rebased=''
  commits=$(jq -c 'map(.sha)' <<<"$merges")
  group=$(jq -cn --arg repo "$repo" --arg base "$base" --argjson c "$commits" \
    '{repo:$repo, base:$base, commits:$c, commands:[], interleaved:[], reason:null}')
  if jq -e 'any(.[]; . == null)' <<<"$commits" >/dev/null; then
    whole_unknown "$group" "the forge reported no merged commit for at least one merge"
    return
  fi
  if jq -e 'any(.[]; .host != "github.com")' <<<"$merges" >/dev/null; then
    whole_unknown "$group" "the pull requests are not on github.com, so no local clone is matched"
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
  if jq -e '.merges | length > 0' <<<"$result" >/dev/null; then
    whole_unknown "$group" "merged commit(s) $(jq -r '.merges | join(" ")' <<<"$result") have more than one parent; no single range revert"
    return
  fi
  while IFS=$'\t' read -r sha url patch; do
    [ -n "$sha" ] || continue
    local_patch=$(git -C "$clone" diff "$sha^1" "$sha" 2>/dev/null | git patch-id --stable | cut -d' ' -f1) || local_patch=''
    [ -n "$patch" ] && [ "$patch" = "$local_patch" ] || rebased+=" $url"
  done < <(jq -r '.[] | select(.commits > 1) | [.sha, .url, (.patch // "")] | @tsv' <<<"$merges")
  if [ -n "$rebased" ]; then
    whole_unknown "$group" "pull request(s)$rebased have more than one commit and the merged commit is not a squash of them (a rebase merge, or the diff could not be compared); no single range revert"
    return
  fi
  if jq -e '.interleaved | length > 0' <<<"$result" >/dev/null; then
    jq -c --argjson g "$group" '.interleaved as $i | $g | .status = "not-contiguous" | .interleaved = $i' <<<"$result"
    return
  fi
  jq -c '.status = "contiguous" | .commands = ["git revert --no-edit " + .commits[0] + "^.." + .commits[-1]]' <<<"$group"
}

WHOLE_ROWS=''
while IFS=$'\t' read -r repo base group_merges; do
  [ -n "$repo" ] || continue
  WHOLE_ROWS+=$(whole_night_group "$repo" "$base" "$group_merges")$'\n'
done < <(jq -r 'group_by([.repo, .base])[]
  | [.[0].repo, .[0].base, (sort_by(.merged_epoch, (.decision_epoch // -1), .number)
      | map({sha:.merged_commit, url, commits:.commit_count, patch:._patch, host:._host}) | tojson)] | @tsv' <<<"$MERGES")

OUT=$({ printf '%s\n' "$MERGES"; jq -sc . <<<"$WHOLE_ROWS"; } | jq -n --argjson since "$SINCE" --argjson until "$UNTIL" --arg repo "$REPO" \
  --argjson not_merged "$NOT_MERGED" --argjson unreadable "$UNREADABLE" '
  input as $merges | input as $whole | {
    schema:"firstmate-night-ledger.v1", since:$since, until:$until,
    repo:(if $repo == "" then null else $repo end),
    merges:($merges | map(del(._host, ._patch))), whole_night:$whole,
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
    (if .review == "unknown" then
      "  review: unknown - no review ledger generation has the merged head \(.merged_head)"
    else
      "  risk: \(.risk.level // "unknown")\(if .risk.reason then " (" + .risk.reason + ")" else "" end)",
      "  reviewers: \(if (.reviewers | length) == 0 then "none recorded" else (.reviewers | join(", ")) end)",
      "  validation: \(if (.validation | length) == 0 then "none recorded" else (.validation | map("\(.kind) \(.by)") | join(", ")) end)",
      "  waiver: \(if .waiver == null then "unknown (no merge decision on the merged head)" elif (.waiver | length) == 0 then "none" else (.waiver | join(", ")) end)",
      "  post-merge: \(.post_merge | post)"
    end),
    "  revert: \(.revert)",
    (.revert_together[] | "  revert together with: \(.url) (shared: \(.files | join(", ")))"),
    (if (.revert_together_incomplete | length) > 0 then
      "  revert together: incomplete - changed-file list truncated for \(.revert_together_incomplete | join(", "))"
    else empty end),
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
