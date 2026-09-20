#!/usr/bin/env bash
# Durable, head-keyed pull-request review ledger and delayed checkpoint driver.
#
# Ledger files live below the data-relative directory configured by the tracked
# review policy, keyed as github--OWNER--REPO--NUMBER.json.
# A head change creates a generation with fresh checkpoint, check, disposition,
# and attestation state. The tracked policy file owns timing and reviewer/model
# requirements; bin/fm-pr-risk.sh is the single risk classifier.
#
# Usage:
#   fm-pr-review.sh init <task-id> <pr-url> [--snapshot <snapshot.json>]
#   fm-pr-review.sh checkpoint <pr-url> [--snapshot <snapshot.json>]
#   fm-pr-review.sh disposition <pr-url> <head> <kind> <id> <addressed|rejected> <evidence>
#   fm-pr-review.sh attest <pr-url> <head> no-mistakes <model> <evidence>
#   fm-pr-review.sh attest <pr-url> <head> independent-agent-review <actor> <evidence>
#   fm-pr-review.sh final-disposition <pr-url> <head> <posted-evidence>
#   fm-pr-review.sh hold <pr-url> <head> <reason>
#   fm-pr-review.sh release-hold <pr-url> <head> <evidence>
#   fm-pr-review.sh ready <pr-url> <head>
#   fm-pr-review.sh merge-decision <pr-url> [--snapshot <snapshot.json>]
#   fm-pr-review.sh merge <task-id> <pr-url> [fm-pr-merge args...]
#   fm-pr-review.sh show <pr-url>
#   fm-pr-review.sh poll
#   fm-pr-review.sh arm|disarm
#
# `poll` is the only watcher-facing command. It performs no network access and
# prints at most one line when one or more ledger checkpoints are due. The
# existing watcher runs that authenticated check on its normal cadence. A
# supervisor handles the wake with `checkpoint`, whose pending-review result
# advances the ledger through the bounded backoff configured in the policy.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
POLICY="$ROOT/.github/firstmate-review-policy.json"
LEDGER_DIR=
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { printf 'fm-pr-review: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
need_tools() {
  local ledger_relative
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  [ -f "$POLICY" ] && [ ! -L "$POLICY" ] || die 'review policy configuration is unavailable'
  ledger_relative=$(jq -er '.ledger_directory | select(type == "string" and length > 0)' "$POLICY") \
    || die 'review ledger directory configuration is invalid'
  case "$ledger_relative" in
    /*|.|..|*/../*|../*|*/..|*//*|*[!A-Za-z0-9._/-]*) die 'review ledger directory configuration is unsafe' ;;
  esac
  LEDGER_DIR="$DATA/$ledger_relative"
}
now_epoch() {
  if [ -n "${FM_REVIEW_NOW_EPOCH:-}" ]; then printf '%s\n' "$FM_REVIEW_NOW_EPOCH"; else date -u +%s; fi
}
now_iso() {
  if [ -n "${FM_REVIEW_NOW:-}" ]; then printf '%s\n' "$FM_REVIEW_NOW"; else date -u +%Y-%m-%dT%H:%M:%SZ; fi
}
parse_url() {
  fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || die 'expected a canonical GitHub pull-request URL'
  URL=$FM_PR_URL
  LEDGER="$LEDGER_DIR/github--$FM_PR_OWNER--$FM_PR_REPO--$FM_PR_NUMBER.json"
}
validate_snapshot() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || die 'review snapshot is unavailable'
  jq -e --arg url "$URL" '
    .schema == "firstmate-pr-review-snapshot.v1" and .url == $url and
    (.head | type == "string" and test("^[0-9a-fA-F]{40}$")) and
    (.files | type == "array" and length > 0) and
    (.pending_reviews | type == "array" and all(.[]; type == "string")) and
    (.comments | type == "array" and all(.[];
      (.kind|type == "string") and (.id|type == "string") and
      (.body|type == "string") and (.url|type == "string"))) and
    (.checks | type == "array" and all(.[];
      (.name|type == "string") and (.status|type == "string") and
      (.conclusion|type == "string") and .required == true))
  ' "$file" >/dev/null || die 'review snapshot is invalid or belongs to another pull request'
}
snapshot_arg() {
  SNAPSHOT=
  if [ "${1:-}" = --snapshot ]; then
    [ -n "${2:-}" ] && [ "$#" -eq 2 ] || die '--snapshot requires exactly one file'
    SNAPSHOT=$2
  elif [ "$#" -ne 0 ]; then
    die 'unexpected arguments after pull-request URL'
  fi
  if [ -z "$SNAPSHOT" ]; then
    SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-live.XXXXXX") || die 'could not create snapshot file'
    SNAPSHOT_TEMP=1
    "$SCRIPT_DIR/fm-pr-review-snapshot.sh" "$URL" "$SNAPSHOT" || die 'live review collection failed'
  fi
  validate_snapshot "$SNAPSHOT"
}
ledger_valid() {
  [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] || return 1
  jq -e --arg url "$URL" '
    .schema == "firstmate-pr-review-ledger.v1" and .url == $url and
    (.generations | type == "array" and length > 0) and
    (.current_head | type == "string")
  ' "$LEDGER" >/dev/null 2>&1
}
publish() {
  local source=$1 staged device
  [ -d "$LEDGER_DIR" ] && [ ! -L "$LEDGER_DIR" ] || die 'ledger directory is unavailable'
  device=$(fm_pr_file_device "$LEDGER_DIR") || die 'ledger directory is unavailable'
  fm_pr_regular_destination_on_device_or_absent "$LEDGER" "$device" || die 'ledger destination is unsafe'
  staged=$(mktemp "$LEDGER_DIR/.fm-pr-review-ledger.XXXXXX") || die 'could not stage review ledger'
  cp "$source" "$staged"
  chmod 0600 "$staged"
  jq -e . "$staged" >/dev/null || { rm -f -- "$staged"; die 'staged review ledger is invalid'; }
  fm_pr_regular_destination_on_device_or_absent "$LEDGER" "$device" || { rm -f -- "$staged"; die 'ledger destination changed'; }
  mv -f -- "$staged" "$LEDGER"
}
new_generation() {
  local task=$1 snapshot=$2 target=$3 risk checkpoint_seconds epoch iso head not_before
  risk=$(mktemp "${TMPDIR:-/tmp}/fm-pr-risk.XXXXXX") || die 'could not stage risk classification'
  jq '.files' "$snapshot" > "$risk.files"
  "$SCRIPT_DIR/fm-pr-risk.sh" "$risk.files" > "$risk" || { rm -f -- "$risk" "$risk.files"; die 'risk classification failed'; }
  rm -f -- "$risk.files"
  checkpoint_seconds=$(jq -er '.checkpoint_seconds' "$POLICY") || die 'checkpoint policy is invalid'
  epoch=$(now_epoch); iso=$(now_iso); head=$(jq -r .head "$snapshot"); not_before=$((epoch + checkpoint_seconds))
  if [ -s "$target" ]; then
    jq --arg task "$task" --arg head "$head" --arg at "$iso" \
      --argjson epoch "$epoch" --argjson not_before "$not_before" --slurpfile risk "$risk" '
      .current_head as $old_head
      | .generations[-1].merge_decision as $prior_decision
      | .task = (if $task == "" then .task else $task end)
      | .current_head = $head
      | .generations += [{head:$head,created_at:$at,created_epoch:$epoch,
          risk:$risk[0],not_before_epoch:$not_before,next_checkpoint_epoch:$not_before,
          retry_index:0,checkpoints:[],review_items:[],attestations:[],final_disposition:null,
          merge_decision:(if $prior_decision.decision == "hold"
            then $prior_decision + {carried_from_head:$old_head} else null end)}]
    ' "$target" > "$target.next"
  else
    jq -n --arg task "$task" --arg url "$URL" --arg head "$head" --arg at "$iso" \
      --argjson epoch "$epoch" --argjson not_before "$not_before" --slurpfile risk "$risk" '{
      schema:"firstmate-pr-review-ledger.v1",task:$task,url:$url,current_head:$head,
      generations:[{head:$head,created_at:$at,created_epoch:$epoch,risk:$risk[0],
        not_before_epoch:$not_before,next_checkpoint_epoch:$not_before,retry_index:0,
        checkpoints:[],review_items:[],attestations:[],final_disposition:null,merge_decision:null}]}' > "$target.next"
  fi
  rm -f -- "$risk"
  mv -f -- "$target.next" "$target"
}
ensure_generation() {
  local task=$1 snapshot=$2 work=$3 head
  head=$(jq -r .head "$snapshot")
  if [ ! -f "$work" ]; then
    new_generation "$task" "$snapshot" "$work"
  elif [ "$(jq -r .current_head "$work")" != "$head" ]; then
    new_generation "$task" "$snapshot" "$work"
  fi
}
checkpoint_apply() {
  local task=$1 snapshot=$2 work=$3 epoch iso pending retry backoff_count backoff next
  ensure_generation "$task" "$snapshot" "$work"
  epoch=$(now_epoch); iso=$(now_iso); pending=$(jq '.pending_reviews | length' "$snapshot")
  retry=$(jq '.generations[-1].retry_index' "$work")
  backoff_count=$(jq '.pending_retry_backoff_seconds | length' "$POLICY")
  next=null
  if [ "$pending" -gt 0 ]; then
    [ "$retry" -lt "$backoff_count" ] || retry=$((backoff_count - 1))
    backoff=$(jq -r ".pending_retry_backoff_seconds[$retry]" "$POLICY")
    next=$((epoch + backoff))
  elif [ "$epoch" -lt "$(jq '.generations[-1].not_before_epoch' "$work")" ]; then
    next=$(jq '.generations[-1].not_before_epoch' "$work")
  fi
  jq --arg at "$iso" --argjson epoch "$epoch" --argjson next "$next" --slurpfile snap "$snapshot" '
    .generations[-1] as $g
    | ($snap[0].comments | map(. + {fingerprint:([.kind,.id,.body,.head,.updated_at] | @json)})) as $incoming
    | .generations[-1].checkpoints += [{at:$at,at_epoch:$epoch,head:$snap[0].head,
        pending_reviews:$snap[0].pending_reviews,checks:$snap[0].checks,
        comment_ids:($incoming | map([.kind,.id]))}]
    | .generations[-1].review_items = (
        [$incoming[] as $item
          | ($g.review_items | map(select(.kind == $item.kind and .id == $item.id)) | first // {}) as $old
          | $item + {present:true,
              disposition:(if $old.fingerprint == $item.fingerprint then ($old.disposition // null) else null end),
              evidence:(if $old.fingerprint == $item.fingerprint then ($old.evidence // null) else null end),
              disposed_at:(if $old.fingerprint == $item.fingerprint then ($old.disposed_at // null) else null end)}]
        + [$g.review_items[] as $old
          | select(any($incoming[]; .kind == $old.kind and .id == $old.id) | not)
          | $old + {present:false}])
    | .generations[-1].retry_index = (if ($snap[0].pending_reviews | length) > 0 then (.generations[-1].retry_index + 1) else 0 end)
    | .generations[-1].next_checkpoint_epoch = $next
    | .generations[-1].merge_decision = (if .generations[-1].merge_decision.decision == "merge" then null else .generations[-1].merge_decision end)
  ' "$work" > "$work.next"
  mv -f -- "$work.next" "$work"
}
ready_check() {
  local head=$1 errors model independent risk
  ledger_valid || die 'review ledger is unavailable'
  errors=$(jq -r --arg head "$head" --slurpfile policy "$POLICY" '
    .generations[-1] as $g
    | ($policy[0].high_stakes.no_mistakes_model) as $model
    | ($policy[0].high_stakes.independent_agent_reviews) as $needed
    | [
      (if .current_head == $head and $g.head == $head then empty else "ledger generation does not match the head to merge" end),
      (if $g.merge_decision.decision != "hold" then empty else "pull request is held: " + ($g.merge_decision.reason // "no reason recorded") end),
      (if any($g.checkpoints[]; .head == $head and .at_epoch >= $g.not_before_epoch) then empty else "ten-minute review checkpoint has not completed on this head" end),
      (if ($g.checkpoints | length) > 0 and ($g.checkpoints[-1].pending_reviews | length) == 0 then empty else "an explicitly pending review still needs bounded-backoff retry" end),
      (if ($g.checkpoints | length) > 0 and all($g.checkpoints[-1].checks[]; .status == "COMPLETED" and (.conclusion == "pass" or .conclusion == "skipping")) then empty else "a required check is not green on this head" end),
      (if all($g.review_items[]; (.disposition == "addressed" or .disposition == "rejected") and (.evidence | type == "string" and length > 0)) then empty else "a reviewer comment, submitted review, or inline thread lacks a disposition with evidence" end),
      (if $g.final_disposition != null
          and ($g.final_disposition.evidence | type == "string" and length > 0)
          and $g.final_disposition.state_digest == ({pending:$g.checkpoints[-1].pending_reviews,
            checks:($g.checkpoints[-1].checks | map({name,state,bucket,url,status,conclusion,required})),
            items:($g.review_items | map({kind,id,fingerprint,disposition,evidence}))} | @json)
        then empty else "final disposition and evidence have not been posted for the latest review state on this head" end),
      (if $g.risk.level != "high" or any($g.attestations[]; .kind == "no-mistakes" and .model == $model and .head == $head) then empty else "high-stakes work lacks a no-mistakes attestation for the configured exact model" end),
      (if $g.risk.level != "high" or ([ $g.attestations[] | select(.kind == "independent-agent-review" and .head == $head) ] | length) >= $needed then empty else "high-stakes work lacks an independent agent review on this head" end)
    ] | .[]' "$LEDGER")
  if [ -n "$errors" ]; then
    printf '%s\n' "$errors" | sed 's/^/review gate: /' >&2
    return 1
  fi
  risk=$(jq -r '.generations[-1].risk.level' "$LEDGER")
  model=$(jq -r '.generations[-1].attestations[]? | select(.kind == "no-mistakes") | .model' "$LEDGER" | tail -1)
  independent=$(jq '[.generations[-1].attestations[] | select(.kind == "independent-agent-review")] | length' "$LEDGER")
  printf 'ready: %s head=%s risk=%s%s independent_reviews=%s\n' "$URL" "$head" "$risk" "${model:+ no_mistakes_model=$model}" "$independent"
}

SNAPSHOT_TEMP=0
cleanup_snapshot() { [ "$SNAPSHOT_TEMP" -eq 0 ] || rm -f -- "${SNAPSHOT:-}"; }
trap cleanup_snapshot EXIT HUP INT TERM
need_tools
cmd=${1:-}
shift || true
case "$cmd" in
  -h|--help) usage ;;
  init)
    [ "$#" -ge 2 ] || die 'init requires task id and pull-request URL'
    TASK=$1; parse_url "$2"; shift 2
    fm_pr_task_id_valid "$TASK" || die 'invalid task id'
    snapshot_arg "$@"
    [ -d "$DATA" ] && [ ! -L "$DATA" ] || die 'data directory is unavailable'
    mkdir -p "$LEDGER_DIR"; [ ! -L "$LEDGER_DIR" ] || die 'ledger directory is unsafe'
    WORK=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ledger.XXXXXX")
    if ledger_valid; then
      cp "$LEDGER" "$WORK"
    elif [ -e "$LEDGER" ] || [ -L "$LEDGER" ]; then
      rm -f -- "$WORK"
      die 'existing review ledger is unreadable; refusing to replace it'
    else
      : > "$WORK"
    fi
    ensure_generation "$TASK" "$SNAPSHOT" "$WORK"
    publish "$WORK"; rm -f -- "$WORK"
    printf 'initialized: %s head=%s risk=%s checkpoint_due=%s\n' "$URL" "$(jq -r .current_head "$LEDGER")" \
      "$(jq -r '.generations[-1].risk.level' "$LEDGER")" "$(jq -r '.generations[-1].next_checkpoint_epoch' "$LEDGER")"
    ;;
  checkpoint)
    [ "$#" -ge 1 ] || die 'checkpoint requires a pull-request URL'
    parse_url "$1"; shift
    ledger_valid || die 'review ledger is unavailable; initialize it first'
    snapshot_arg "$@"
    WORK=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ledger.XXXXXX"); cp "$LEDGER" "$WORK"
    checkpoint_apply "$(jq -r .task "$WORK")" "$SNAPSHOT" "$WORK"
    publish "$WORK"; rm -f -- "$WORK"
    printf 'checkpoint: %s head=%s pending_reviews=%s review_items=%s next=%s\n' "$URL" \
      "$(jq -r .current_head "$LEDGER")" "$(jq '.generations[-1].checkpoints[-1].pending_reviews | length' "$LEDGER")" \
      "$(jq '.generations[-1].review_items | length' "$LEDGER")" "$(jq -r '.generations[-1].next_checkpoint_epoch // "none"' "$LEDGER")"
    ;;
  disposition)
    [ "$#" -eq 6 ] || die 'disposition requires URL, head, kind, id, addressed|rejected, and evidence'
    parse_url "$1"; HEAD=$2; KIND=$3; ITEM=$4; DISP=$5; EVIDENCE=$6
    case "$DISP" in addressed|rejected) ;; *) die 'disposition must be addressed or rejected' ;; esac
    [ -n "$EVIDENCE" ] || die 'disposition evidence must not be empty'
    ledger_valid || die 'review ledger is unavailable'
    [ "$(jq -r .current_head "$LEDGER")" = "$HEAD" ] || die 'disposition head is not the current ledger generation'
    COUNT=$(jq --arg kind "$KIND" --arg id "$ITEM" '[.generations[-1].review_items[] | select(.kind == $kind and .id == $id)] | length' "$LEDGER")
    [ "$COUNT" -eq 1 ] || die 'review item is absent or ambiguous'
    WORK=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ledger.XXXXXX")
    jq --arg kind "$KIND" --arg id "$ITEM" --arg disp "$DISP" --arg evidence "$EVIDENCE" --arg at "$(now_iso)" '
      .generations[-1].review_items |= map(if .kind == $kind and .id == $id then . + {disposition:$disp,evidence:$evidence,disposed_at:$at} else . end)
      | .generations[-1].merge_decision = (if .generations[-1].merge_decision.decision == "merge" then null else .generations[-1].merge_decision end)' "$LEDGER" > "$WORK"
    publish "$WORK"; rm -f -- "$WORK"
    printf 'recorded: %s %s/%s %s\n' "$URL" "$KIND" "$ITEM" "$DISP"
    ;;
  attest)
    [ "$#" -eq 5 ] || die 'attest requires URL, head, kind, subject, and evidence'
    parse_url "$1"; HEAD=$2; KIND=$3; SUBJECT=$4; EVIDENCE=$5
    case "$KIND" in no-mistakes|independent-agent-review) ;; *) die 'unknown attestation kind' ;; esac
    [ -n "$SUBJECT" ] && [ -n "$EVIDENCE" ] || die 'attestation subject and evidence must not be empty'
    ledger_valid || die 'review ledger is unavailable'
    [ "$(jq -r .current_head "$LEDGER")" = "$HEAD" ] || die 'attestation head is not the current ledger generation'
    WORK=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ledger.XXXXXX")
    jq --arg kind "$KIND" --arg subject "$SUBJECT" --arg evidence "$EVIDENCE" --arg head "$HEAD" --arg at "$(now_iso)" '
      .generations[-1].attestations += [({kind:$kind,head:$head,evidence:$evidence,at:$at}
        + if $kind == "no-mistakes" then {model:$subject} else {actor:$subject} end)]
      | .generations[-1].merge_decision = (if .generations[-1].merge_decision.decision == "merge" then null else .generations[-1].merge_decision end)' "$LEDGER" > "$WORK"
    publish "$WORK"; rm -f -- "$WORK"
    printf 'attested: %s head=%s kind=%s subject=%s\n' "$URL" "$HEAD" "$KIND" "$SUBJECT"
    ;;
  final-disposition)
    [ "$#" -eq 3 ] || die 'final-disposition requires URL, head, and posted evidence'
    parse_url "$1"; HEAD=$2; EVIDENCE=$3
    [ -n "$EVIDENCE" ] || die 'posted disposition evidence must not be empty'
    ledger_valid || die 'review ledger is unavailable'
    [ "$(jq -r .current_head "$LEDGER")" = "$HEAD" ] || die 'final-disposition head is not the current ledger generation'
    WORK=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ledger.XXXXXX")
    jq --arg head "$HEAD" --arg evidence "$EVIDENCE" --arg at "$(now_iso)" '
      .generations[-1] as $g
      | .generations[-1].final_disposition={head:$head,evidence:$evidence,posted_at:$at,
          state_digest:({pending:$g.checkpoints[-1].pending_reviews,
            checks:($g.checkpoints[-1].checks | map({name,state,bucket,url,status,conclusion,required})),
            items:($g.review_items | map({kind,id,fingerprint,disposition,evidence}))} | @json)}
      | .generations[-1].merge_decision = (if .generations[-1].merge_decision.decision == "merge" then null else .generations[-1].merge_decision end)' "$LEDGER" > "$WORK"
    publish "$WORK"; rm -f -- "$WORK"
    printf 'final-disposition: %s head=%s evidence=%s\n' "$URL" "$HEAD" "$EVIDENCE"
    ;;
  hold)
    [ "$#" -eq 3 ] || die 'hold requires URL, head, and reason'
    parse_url "$1"; HEAD=$2; REASON=$3
    [ -n "$REASON" ] || die 'hold reason must not be empty'
    ledger_valid || die 'review ledger is unavailable'
    [ "$(jq -r .current_head "$LEDGER")" = "$HEAD" ] || die 'hold head is not the current ledger generation'
    WORK=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ledger.XXXXXX")
    jq --arg head "$HEAD" --arg reason "$REASON" --arg at "$(now_iso)" '
      .generations[-1].merge_decision={decision:"hold",reviewed_head:$head,verified_head:$head,verified_at:$at,reason:$reason}' "$LEDGER" > "$WORK"
    publish "$WORK"; rm -f -- "$WORK"
    printf 'held: %s head=%s reason=%s\n' "$URL" "$HEAD" "$REASON"
    ;;
  release-hold)
    [ "$#" -eq 3 ] || die 'release-hold requires URL, head, and evidence'
    parse_url "$1"; HEAD=$2; EVIDENCE=$3
    [ -n "$EVIDENCE" ] || die 'hold-release evidence must not be empty'
    ledger_valid || die 'review ledger is unavailable'
    [ "$(jq -r .current_head "$LEDGER")" = "$HEAD" ] || die 'hold-release head is not the current ledger generation'
    [ "$(jq -r '.generations[-1].merge_decision.decision // ""' "$LEDGER")" = hold ] || die 'current generation is not held'
    WORK=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ledger.XXXXXX")
    jq --arg evidence "$EVIDENCE" --arg at "$(now_iso)" '
      .generations[-1].hold_release={evidence:$evidence,released_at:$at}
      | .generations[-1].merge_decision=null' "$LEDGER" > "$WORK"
    publish "$WORK"; rm -f -- "$WORK"
    printf 'hold-released: %s head=%s evidence=%s\n' "$URL" "$HEAD" "$EVIDENCE"
    ;;
  ready)
    [ "$#" -eq 2 ] || die 'ready requires pull-request URL and head'
    parse_url "$1"; ready_check "$2"
    ;;
  merge-decision)
    [ "$#" -ge 1 ] || die 'merge-decision requires pull-request URL'
    parse_url "$1"; shift
    ledger_valid || die 'review ledger is unavailable'
    snapshot_arg "$@"
    WORK=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ledger.XXXXXX"); cp "$LEDGER" "$WORK"
    checkpoint_apply "$(jq -r .task "$WORK")" "$SNAPSHOT" "$WORK"
    publish "$WORK"; rm -f -- "$WORK"
    HEAD=$(jq -r .head "$SNAPSHOT")
    ready_check "$HEAD" >/dev/null
    WORK=$(mktemp "${TMPDIR:-/tmp}/fm-pr-review-ledger.XXXXXX")
    jq --arg head "$HEAD" --arg at "$(now_iso)" --argjson epoch "$(now_epoch)" '
      .generations[-1].merge_decision={decision:"merge",reviewed_head:$head,verified_head:$head,verified_at:$at,verified_epoch:$epoch}' "$LEDGER" > "$WORK"
    publish "$WORK"; rm -f -- "$WORK"
    printf 'merge-decision: %s verified_head=%s verified_at=%s\n' "$URL" "$HEAD" "$(jq -r '.generations[-1].merge_decision.verified_at' "$LEDGER")"
    ;;
  merge)
    [ "$#" -ge 2 ] || die 'merge requires task id and pull-request URL'
    TASK=$1; parse_url "$2"; shift 2
    fm_pr_task_id_valid "$TASK" || die 'invalid task id'
    "$0" merge-decision "$URL"
    FM_PR_REVIEW_EXPECTED_HEAD=$(jq -er '.generations[-1].merge_decision.verified_head' "$LEDGER") \
      || die 'reviewed-head merge handoff is unavailable'
    export FM_PR_REVIEW_EXPECTED_HEAD
    exec "$SCRIPT_DIR/fm-pr-merge.sh" "$TASK" "$URL" "$@"
    ;;
  show)
    [ "$#" -eq 1 ] || die 'show requires pull-request URL'
    parse_url "$1"; ledger_valid || die 'review ledger is unavailable'; jq . "$LEDGER"
    ;;
  poll)
    [ "$#" -eq 0 ] || die 'poll takes no arguments'
    [ -d "$LEDGER_DIR" ] && [ ! -L "$LEDGER_DIR" ] || exit 0
    NOW=$(now_epoch); DUE=; COUNT=0; BAD=0; BADFILE=
    for file in "$LEDGER_DIR"/*.json; do
      [ -e "$file" ] || continue
      if [ ! -f "$file" ] || [ -L "$file" ] \
        || ! jq -e '.schema == "firstmate-pr-review-ledger.v1" and (.url | type == "string") and (.generations | type == "array" and length > 0)' "$file" >/dev/null 2>&1; then
        BAD=$((BAD + 1)); BADFILE=${BADFILE:-$(basename "$file")}; continue
      fi
      NEXT=$(jq -er '.generations[-1].next_checkpoint_epoch // empty' "$file" 2>/dev/null || true)
      case "$NEXT" in ''|*[!0-9]*) continue ;; esac
      [ "$NEXT" -le "$NOW" ] || continue
      COUNT=$((COUNT + 1)); DUE="${DUE:+$DUE,}$(jq -r .url "$file")"
    done
    if [ "$BAD" -gt 0 ]; then
      printf 'PR review ledger attention: unreadable=%s first=%s due=%s%s\n' "$BAD" "$BADFILE" "$COUNT" "${DUE:+ urls=$DUE}"
    elif [ "$COUNT" -gt 0 ]; then
      printf 'PR review checkpoint due (%s): %s\n' "$COUNT" "$DUE"
    fi
    ;;
  arm)
    [ "$#" -eq 0 ] || die 'arm takes no arguments'
    mkdir -p "$STATE"; [ ! -L "$STATE" ] || die 'state directory is unsafe'
    CHECK="$STATE/review-policy.check.sh"
    [ ! -e "$CHECK" ] || { [ -f "$CHECK" ] && [ ! -L "$CHECK" ]; } || die 'review check destination is unsafe'
    TMP=$(mktemp "$STATE/.fm-pr-review-check.XXXXXX")
    printf '#!/usr/bin/env bash\nexec %q poll\n' "$SCRIPT_DIR/fm-pr-review.sh" > "$TMP"
    chmod 0700 "$TMP"; mv -f -- "$TMP" "$CHECK"
    "$SCRIPT_DIR/fm-check-register.sh" review-policy >/dev/null
    printf 'armed: state/review-policy.check.sh\n'
    ;;
  disarm)
    [ "$#" -eq 0 ] || die 'disarm takes no arguments'
    "$SCRIPT_DIR/fm-check-unregister.sh" review-policy
    ;;
  *) usage >&2; exit 2 ;;
esac
