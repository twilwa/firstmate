#!/usr/bin/env bash
# Child-side offer publication and primary-side receipt recovery for local-only
# secondmate custody. Record formats, validators and the containment proof are
# owned by bin/fm-local-handoff-lib.sh; the guarded landing itself is owned by
# bin/fm-merge-local.sh and is deliberately NOT reachable from here.
#
# Usage:
#   fm-local-handoff.sh offer <task-id>
#       Run in the SECONDMATE home. Publishes an immutable head-pinned offer
#       plus a git bundle holding exactly that head, for the task's local-only
#       branch fm/<task-id>. Refuses a dirty worktree, an unbound project, a
#       missing parent binding, or a project whose parent route has changed.
#       Re-running with the same head republishes the same identity; a moved
#       head publishes a NEW offer, so an approval pinned to the old head
#       cannot carry over.
#
#   fm-local-handoff.sh request <landing-id> --offer <offer-file>
#       Run in the PRIMARY home while the landing row <landing-id> is HELD for
#       the captain. Pins that row's pending approval to this offer's exact
#       commit and identity in a parent-owned landing record, so the release
#       the captain then records can never be inherited by a later head: a
#       changed offer needs its own landing row and its own pin. It grants
#       nothing on its own - bin/fm-captain-hold.sh remains the only approval
#       owner. A published pin is immutable: re-running with the same identity
#       repeats itself, while a different offer, an already landed record, or a
#       record it cannot read all refuse instead of replacing it. The pin is
#       published only if this landing has no record at all, then the hold is
#       re-read and a pin the captain's answer overtook is withdrawn, all under
#       the landing's own control lock that bin/fm-merge-local.sh takes, so no
#       landing can consume and no second request can overwrite a pin that is
#       still being taken.
#
#   fm-local-handoff.sh receipt <offer-file> --landing <landing-id>
#       Run in the PRIMARY home. Re-proves that the offered head is contained
#       in the primary clone's default branch, completes the parent's own
#       landing record, publishes (or confirms) the landing receipt in the
#       child home, then closes the landing row <landing-id>. Unless the
#       landing was already fully acknowledged, nothing is written while that
#       row is missing, unreadable, or held for the captain. This is the
#       idempotent recovery path for a fast-forward that landed but whose
#       evidence publication or row close failed; it NEVER merges anything, so
#       a retry cannot land a second time.
#
# Every subcommand fails closed: a missing, stale, malformed, or mismatched
# identity refuses and preserves the work rather than guessing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-local-handoff-lib.sh
. "$SCRIPT_DIR/fm-local-handoff-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# `receipt` closes the landing row through the backlog transition owner.
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# The fleet's existing lock owner. `request` takes the same per-landing control
# lock bin/fm-merge-local.sh holds, so taking a pin and consuming one are
# serialized by the lock that already guards this landing.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

SUB_HOME_MARKER=.fm-secondmate-home
SUB_HOME_PARENT_MARKER=.fm-secondmate-parent

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

resolved_path() {
  local target=$1
  if [ -d "$target" ]; then
    ( cd "$target" && pwd -P )
  else
    printf '%s\n' "$target"
  fi
}

meta_field() {  # <meta> <key>
  local meta=$1 key=$2
  grep "^$key=" "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Prove the secondmate identity and parent route of the home this command is
# running in from the home's own markers, rather than inferring either from a
# path or an argument. Sets CHILD_SECONDMATE and CHILD_PARENT_HOME in the
# caller's shell, because the parent-record parser reports through globals and
# a command substitution would strand them in a subshell.
CHILD_SECONDMATE=
CHILD_PARENT_HOME=
child_identity() {  # <home>
  local home=$1 id
  [ -f "$home/$SUB_HOME_MARKER" ] && [ ! -L "$home/$SUB_HOME_MARKER" ] \
    || die "$home is not a seeded secondmate home (no $SUB_HOME_MARKER)"
  id=$(head -1 "$home/$SUB_HOME_MARKER" 2>/dev/null || true)
  fm_local_handoff_valid_slug "$id" || die "$home has a malformed $SUB_HOME_MARKER"
  fm_secondmate_parent_record_parse "$home/$SUB_HOME_PARENT_MARKER" \
    || die "$home has no readable parent binding at $SUB_HOME_PARENT_MARKER"
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || die "local-only custody requires a local parent route; $home is route $FM_SECONDMATE_PARENT_ROUTE"
  CHILD_SECONDMATE=$id
  CHILD_PARENT_HOME=$FM_SECONDMATE_PARENT_HOME
}

# Does an existing offer record describe exactly this publication? Every field
# the offer pins is compared, because "unchanged" is what tells the operator no
# new approval is needed; a record that differs anywhere is a different offer.
offer_identity_unchanged() {
  # <existing-blob> <secondmate> <child-home> <parent-home> <project>
  # <child-project> <task> <spawn-gen> <branch> <head> <bundle>
  local blob=$1
  shift
  local keys='secondmate child_home parent_home project child_project task spawn_gen branch head bundle'
  local key
  for key in $keys; do
    [ "$(fm_local_handoff_field "$blob" "$key")" = "$1" ] || return 1
    shift
  done
}

command_offer() {  # <task-id>
  local id=$1 home meta project_path project child_project parent_home spawn_gen
  local binding branch head bundle offer_path secondmate dirty existing_blob

  fm_local_handoff_valid_slug "$id" || die "task id must be a privacy-safe slug: $id"
  home=$(resolved_path "$FM_HOME")
  child_identity "$home"
  secondmate=$CHILD_SECONDMATE
  parent_home=$CHILD_PARENT_HOME

  meta="$STATE/$id.meta"
  [ -f "$meta" ] || die "no record for task $id at $meta"
  [ "$(meta_field "$meta" mode)" = local-only ] \
    || die "task $id is not mode=local-only; only local-only work uses the landing offer"
  project_path=$(meta_field "$meta" project)
  [ -n "$project_path" ] || die "task $id records no project"
  project=$(basename "$project_path")
  fm_local_handoff_valid_slug "$project" || die "task $id records a malformed project name"
  child_project=$(resolved_path "$project_path")
  [ -d "$child_project" ] || die "project clone for task $id is not present at $child_project"

  fm_local_handoff_binding_load "$home" "$project" || die "$FM_LOCAL_HANDOFF_ERROR"
  binding=$FM_LOCAL_HANDOFF_RECORD
  # The child proves only that the binding names the parent this home is
  # actually routed to. Which clone in that parent holds the project is the
  # parent's own fact, and the parent re-proves it against its own projects
  # directory before it lands anything.
  [ "$(fm_local_handoff_field "$binding" parent_home)" = "$parent_home" ] \
    || die "project $project is bound to a different parent home than this home's parent route"

  spawn_gen=$(meta_field "$meta" spawn_gen)
  [ -n "$spawn_gen" ] || spawn_gen=0
  case "$spawn_gen" in
    ''|*[!0-9]*) die "task $id records a malformed incarnation" ;;
  esac

  branch="fm/$id"
  git -C "$child_project" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
    || die "branch $branch does not exist in $child_project"
  head=$(git -C "$child_project" rev-parse "refs/heads/$branch")
  fm_local_handoff_valid_sha "$head" || die "branch $branch does not resolve to a commit"

  # Uncommitted work is never offered: the offer pins a commit, so anything
  # still in the worktree would be silently excluded from what the primary lands.
  local worktree
  worktree=$(meta_field "$meta" worktree)
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    dirty=$(git -C "$worktree" status --porcelain 2>/dev/null | head -1 || true)
    [ -z "$dirty" ] || die "worktree $worktree has uncommitted changes; commit them before offering task $id"
  fi

  offer_path=$(fm_local_handoff_offer_path "$STATE" "$id")
  bundle=$(fm_local_handoff_bundle_path "$STATE" "$id")

  # An existing offer that does not match this publication in EVERY identity
  # field is replaced wholesale rather than edited, so a stale head, a stale
  # parent, or a stale clone path can never be mixed with the new identity and
  # then reported as unchanged. A parent approval pinned to the old record then
  # refuses on the mismatch, which is the intended outcome.
  if [ -e "$offer_path" ]; then
    if fm_local_handoff_offer_load "$offer_path"; then
      existing_blob=$FM_LOCAL_HANDOFF_RECORD
      if [ -f "$bundle" ] \
        && offer_identity_unchanged "$existing_blob" \
          "$secondmate" "$home" "$parent_home" "$project" "$child_project" \
          "$id" "$spawn_gen" "$branch" "$head" "$bundle"; then
        printf 'offer=%s\n' "$offer_path"
        printf 'head=%s\n' "$head"
        printf 'unchanged=1\n'
        return 0
      fi
    fi
  fi

  rm -f -- "$bundle" 2>/dev/null || true
  mkdir -p "$STATE" || die "cannot create state directory $STATE"
  git -C "$child_project" bundle create "$bundle" "refs/heads/$branch" >/dev/null 2>&1 \
    || die "could not bundle $branch from $child_project"
  git -C "$child_project" bundle verify "$bundle" >/dev/null 2>&1 \
    || die "the bundle written for $branch does not verify"

  fm_local_handoff_write_record "$offer_path" \
    "schema=$FM_LOCAL_HANDOFF_OFFER_SCHEMA" \
    "secondmate=$secondmate" \
    "child_home=$home" \
    "parent_home=$parent_home" \
    "project=$project" \
    "child_project=$child_project" \
    "task=$id" \
    "spawn_gen=$spawn_gen" \
    "branch=$branch" \
    "head=$head" \
    "bundle=$bundle" \
    "created=$(date +%s)" \
    || die "$FM_LOCAL_HANDOFF_ERROR"

  printf 'offer=%s\n' "$offer_path"
  printf 'head=%s\n' "$head"
}

# An absolute path for a record that must name one exact file, resolved
# without following the file itself into a different identity.
absolute_file() {  # <path>
  local path=$1 dir
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || die "cannot resolve the directory of $path"
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

# Every parent-side command proves the same things about an offer before it
# writes anything: the offer's identity still holds on both sides, this home is
# the project's primary rather than another bound copy, and the project is
# still registered local-only. Reports the project through PARENT_PROJECT.
PARENT_HOME=
PARENT_PROJECTS=
PARENT_PROJECT=
parent_side_offer_checks() {  # <offer-blob>
  local blob=$1 project
  PARENT_HOME=$(resolved_path "$FM_HOME")
  PARENT_PROJECTS=$(resolved_path "$PROJECTS")
  fm_local_handoff_offer_identity_proves "$blob" "$PARENT_HOME" "$DATA" "$PARENT_PROJECTS" \
    || die "$FM_LOCAL_HANDOFF_ERROR"
  project=$(fm_local_handoff_field "$blob" project)
  if fm_local_handoff_binding_present "$PARENT_HOME" "$project"; then
    die "this home's clone of $project is itself a bound local-only copy; only the home that seeded it lands its work"
  fi
  PARENT_PROJECT="$PARENT_PROJECTS/$project"
}

# Is the landing row still open for the captain? Exit 0 is held; every other
# answer, including "cannot tell", refuses, so the caller states what it is
# refusing rather than guessing.
request_hold_status() {  # <landing-id>
  local landing_id=$1 status=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$landing_id" --distinguish-absent || status=$?
  printf '%s\n' "$status"
}

# The one place a published pin is read by `request`. A pin is immutable, so
# the only outcome that is not a refusal is repeating the identity already
# pinned, which lets an interrupted request be re-run safely.
request_report_existing() {  # <landing-id> <existing-blob> <offer-blob>
  local landing_id=$1 existing=$2 offer=$3
  if [ "$(fm_local_handoff_field "$existing" state)" = landed ]; then
    die "landing $landing_id already records $(fm_local_handoff_field "$existing" head) as landed; pin further work to its own landing record"
  fi
  fm_local_handoff_landing_matches_offer "$existing" "$offer" "$PARENT_HOME" "$PARENT_PROJECT" \
    || die "$FM_LOCAL_HANDOFF_ERROR; a published pin is never replaced, so this offer needs its own landing record"
  printf 'landing=%s\n' "$(fm_local_handoff_landing_path "$DATA" "$landing_id")"
  printf 'head=%s\n' "$(fm_local_handoff_field "$existing" head)"
  printf 'state=%s\n' "$(fm_local_handoff_field "$existing" state)"
  printf 'unchanged=1\n'
}

REQUEST_LOCK=
request_lock_release() {
  [ -z "$REQUEST_LOCK" ] || fm_lock_release "$REQUEST_LOCK" || true
  REQUEST_LOCK=
}

command_request() {  # <landing-id> <offer-file>
  local landing_id=$1 offer_file=$2 blob project head hold_status landing_path

  fm_local_handoff_valid_slug "$landing_id" \
    || die "landing id must be a privacy-safe slug: $landing_id"
  [ -n "$offer_file" ] || die "request needs the offer file it pins"
  fm_local_handoff_offer_load "$offer_file" || die "$FM_LOCAL_HANDOFF_ERROR"
  blob=$FM_LOCAL_HANDOFF_RECORD
  offer_file=$(absolute_file "$offer_file")
  parent_side_offer_checks "$blob"
  project=$(fm_local_handoff_field "$blob" project)
  head=$(fm_local_handoff_field "$blob" head)
  fm_local_handoff_project_still_local_only "$SCRIPT_DIR" "$FM_HOME" "$DATA" "$project" \
    || die "$FM_LOCAL_HANDOFF_ERROR"
  landing_path=$(fm_local_handoff_landing_path "$DATA" "$landing_id")

  # Everything below happens under the landing's own control lock, the same one
  # bin/fm-merge-local.sh holds for this id. That is what makes publishing the
  # pin and re-reading the hold one step to every other actor: no landing can
  # consume a pin that is still being verified, and no second request can be
  # between its own read and its own publication at the same time.
  trap request_lock_release EXIT
  REQUEST_LOCK="$STATE/.control-$landing_id.lock"
  if ! fm_lock_acquire_wait_bounded "$REQUEST_LOCK" 60; then
    REQUEST_LOCK=
    die "landing $landing_id is busy in another command; pin the offer again once that one finishes"
  fi

  # A record that already exists is the durable approval or the durable
  # evidence of a landing, and this path never replaces either.
  if [ -e "$landing_path" ] || [ -L "$landing_path" ]; then
    fm_local_handoff_landing_load "$DATA" "$landing_id" || die "$FM_LOCAL_HANDOFF_ERROR"
    request_report_existing "$landing_id" "$FM_LOCAL_HANDOFF_RECORD" "$blob"
    return 0
  fi

  # The approval itself stays where it has always lived. This only binds the
  # pending call to one exact commit, so it must run while that call is still
  # open; an absent or already released row refuses.
  hold_status=$(request_hold_status "$landing_id")
  case "$hold_status" in
    0) ;;
    1)
      die "landing row $landing_id is not held for the captain; hold it with bin/fm-captain-hold.sh hold $landing_id --reason '<why>' before pinning an offer to it"
      ;;
    3)
      die "this home has no landing row $landing_id; file it and hold it for the captain before pinning an offer to it"
      ;;
    *)
      die "could not determine whether landing row $landing_id is held for the captain; refusing to pin an approval"
      ;;
  esac

  if ! fm_local_handoff_landing_pin "$DATA" "$blob" "$landing_id" "$offer_file" "$PARENT_PROJECT"; then
    if [ "$FM_LOCAL_HANDOFF_RECORD_EXISTS" = 1 ]; then
      fm_local_handoff_landing_load "$DATA" "$landing_id" || die "$FM_LOCAL_HANDOFF_ERROR"
      request_report_existing "$landing_id" "$FM_LOCAL_HANDOFF_RECORD" "$blob"
      return 0
    fi
    die "$FM_LOCAL_HANDOFF_ERROR"
  fi

  # Re-read the hold now that the pin is durable. A release recorded before
  # this point answered a call this pin was not part of, so the pin is
  # withdrawn and nothing inherits that answer; a release recorded after it
  # genuinely post-dates a durable approval.
  hold_status=$(request_hold_status "$landing_id")
  if [ "$hold_status" != 0 ]; then
    fm_local_handoff_landing_withdraw "$DATA" "$blob" "$landing_id" "$offer_file" "$PARENT_PROJECT" \
      || die "the captain's landing row $landing_id stopped being held while this offer was being pinned, and $FM_LOCAL_HANDOFF_ERROR; reconcile that record by hand before landing anything"
    die "the captain's landing row $landing_id stopped being held while this offer was being pinned, so the pin was withdrawn; this offer needs its own held landing row"
  fi

  printf 'landing=%s\n' "$landing_path"
  printf 'head=%s\n' "$head"
  printf 'state=pinned\n'
}

command_receipt() {  # <offer-file> <landing-id>
  local offer_file=$1 landing_id=$2 blob head child_home child_project task existing landing unchanged
  local was_landed=0

  [ -n "$offer_file" ] || die "receipt needs the offer file to answer"
  fm_local_handoff_valid_slug "$landing_id" \
    || die "landing id must be a privacy-safe slug: $landing_id"
  fm_local_handoff_offer_load "$offer_file" || die "$FM_LOCAL_HANDOFF_ERROR"
  blob=$FM_LOCAL_HANDOFF_RECORD

  # The same identity proof the guarded landing runs, so a recovery retry can
  # never accept an offer the landing itself would have refused. The project's
  # registered posture is deliberately NOT re-read here: this path records a
  # landing that already happened rather than authorizing one, and a registry
  # change afterwards must not strand the child's evidence.
  parent_side_offer_checks "$blob"

  head=$(fm_local_handoff_field "$blob" head)
  child_home=$(fm_local_handoff_field "$blob" child_home)
  child_project=$(fm_local_handoff_field "$blob" child_project)
  task=$(fm_local_handoff_field "$blob" task)

  fm_local_handoff_landing_load "$DATA" "$landing_id" || die "$FM_LOCAL_HANDOFF_ERROR"
  landing=$FM_LOCAL_HANDOFF_RECORD
  fm_local_handoff_landing_matches_offer "$landing" "$blob" "$PARENT_HOME" "$PARENT_PROJECT" \
    || die "$FM_LOCAL_HANDOFF_ERROR"

  # Recovery proves the landing from the repository, never from the request:
  # if the fast-forward did not actually happen, this refuses instead of
  # writing evidence that would later authorize discarding live work.
  fm_local_handoff_head_in_default "$PARENT_PROJECT" "$head" \
    || die "$FM_LOCAL_HANDOFF_ERROR"

  [ "$(fm_local_handoff_field "$landing" state)" != landed ] || was_landed=1
  existing=$(fm_local_handoff_receipt_path "${child_home%/}/state" "$task")
  unchanged=0
  if [ -e "$existing" ] \
    && fm_local_handoff_landed_proof "$child_home" "$blob" "$existing" "$child_project"; then
    unchanged=1
  fi

  if [ "$was_landed" = 1 ] && [ "$unchanged" = 1 ]; then
    fm_local_handoff_landing_row_close "$DATA" "$landing_id" --completed || die "$FM_LOCAL_HANDOFF_ERROR"
  else
    fm_local_handoff_landing_row_ready "$DATA" "$landing_id" \
      || die "$FM_LOCAL_HANDOFF_ERROR; recovery records nothing without its approval row"
    if [ "$was_landed" = 0 ]; then
      fm_local_handoff_landing_publish "$DATA" "$landing" "$landing_id" \
        "$(fm_local_handoff_field "$landing" offer)" "$PARENT_PROJECT" landed "$(date +%s)" \
        || die "$FM_LOCAL_HANDOFF_ERROR"
    fi
    if [ "$unchanged" = 0 ]; then
      fm_local_handoff_publish_receipt "$blob" "$PARENT_PROJECT" "$landing_id" \
        || die "$FM_LOCAL_HANDOFF_ERROR"
    fi
    fm_local_handoff_landing_row_close "$DATA" "$landing_id" || die "$FM_LOCAL_HANDOFF_ERROR"
  fi
  printf 'receipt=%s\n' "$existing"
  [ "$unchanged" = 0 ] || printf 'unchanged=1\n'
}

case "${1:-}" in
  offer)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    command_offer "$2"
    ;;
  request)
    [ "$#" -eq 4 ] && [ "$3" = --offer ] || { usage >&2; exit 2; }
    command_request "$2" "$4"
    ;;
  receipt)
    [ "$#" -eq 4 ] && [ "$3" = --landing ] || { usage >&2; exit 2; }
    command_receipt "$2" "$4"
    ;;
  -h|--help|'')
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
