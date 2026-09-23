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
#   fm-local-handoff.sh receipt <offer-file>
#       Run in the PRIMARY home. Re-proves that the offered head is contained
#       in the primary clone's default branch, then publishes (or confirms)
#       the landing receipt in the child home. This is the idempotent recovery
#       path for a fast-forward that landed but whose receipt publication
#       failed; it NEVER merges anything, so a retry cannot land a second time.
#
#   fm-local-handoff.sh verify-receipt <child-home> <task-id>
#       Read-only. Exit 0 only when a receipt exists, matches the task's offer
#       identity, and its head is genuinely contained in the primary clone's
#       default branch right now. bin/fm-teardown.sh asks this before it may
#       treat a bound local-only task's work as landed.
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

SUB_HOME_MARKER=.fm-secondmate-home
SUB_HOME_PARENT_MARKER=.fm-secondmate-parent

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
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

  # An existing offer for a DIFFERENT head is replaced wholesale rather than
  # edited, so the stale head and its bundle can never be mixed with the new
  # identity. A parent approval pinned to the old head then refuses on head
  # mismatch, which is the intended outcome.
  if [ -e "$offer_path" ]; then
    if fm_local_handoff_offer_load "$offer_path"; then
      existing_blob=$FM_LOCAL_HANDOFF_RECORD
      if [ "$(fm_local_handoff_field "$existing_blob" head)" = "$head" ] \
        && [ "$(fm_local_handoff_field "$existing_blob" spawn_gen)" = "$spawn_gen" ] \
        && [ -f "$bundle" ]; then
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

command_receipt() {  # <offer-file>
  local offer_file=$1 blob head parent_home parent_project child_home task existing

  [ -n "$offer_file" ] || die "receipt needs the offer file to answer"
  fm_local_handoff_offer_load "$offer_file" || die "$FM_LOCAL_HANDOFF_ERROR"
  blob=$FM_LOCAL_HANDOFF_RECORD

  parent_home=$(resolved_path "$FM_HOME")
  # The same proof the guarded landing runs, so a recovery retry can never
  # accept an offer the landing itself would have refused.
  fm_local_handoff_offer_identity_proves "$blob" "$parent_home" "$DATA" "$(resolved_path "$PROJECTS")" \
    || die "$FM_LOCAL_HANDOFF_ERROR"

  head=$(fm_local_handoff_field "$blob" head)
  child_home=$(fm_local_handoff_field "$blob" child_home)
  task=$(fm_local_handoff_field "$blob" task)
  parent_project="$(resolved_path "$PROJECTS")/$(fm_local_handoff_field "$blob" project)"

  # Recovery proves the landing from the repository, never from the request:
  # if the fast-forward did not actually happen, this refuses instead of
  # writing a receipt that would later authorize discarding live work.
  fm_local_handoff_head_in_default "$parent_project" "$head" \
    || die "$FM_LOCAL_HANDOFF_ERROR"

  existing=$(fm_local_handoff_receipt_path "${child_home%/}/state" "$task")
  if [ -e "$existing" ]; then
    if fm_local_handoff_receipt_proves "$existing" "$blob"; then
      printf 'receipt=%s\n' "$existing"
      printf 'unchanged=1\n'
      return 0
    fi
  fi
  fm_local_handoff_publish_receipt "$blob" "$parent_project" || die "$FM_LOCAL_HANDOFF_ERROR"
  printf 'receipt=%s\n' "$existing"
}

command_verify_receipt() {  # <child-home> <task-id>
  local child_home=$1 id=$2 offer_file receipt_file blob
  fm_local_handoff_valid_slug "$id" || die "task id must be a privacy-safe slug: $id"
  child_home=$(resolved_path "$child_home")
  offer_file=$(fm_local_handoff_offer_path "$child_home/state" "$id")
  fm_local_handoff_offer_load "$offer_file" || die "$FM_LOCAL_HANDOFF_ERROR"
  blob=$FM_LOCAL_HANDOFF_RECORD
  receipt_file=$(fm_local_handoff_receipt_path "$child_home/state" "$id")
  fm_local_handoff_receipt_proves "$receipt_file" "$blob" || die "$FM_LOCAL_HANDOFF_ERROR"
  printf 'landed=%s\n' "$(fm_local_handoff_field "$blob" head)"
}

case "${1:-}" in
  offer)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    command_offer "$2"
    ;;
  receipt)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    command_receipt "$2"
    ;;
  verify-receipt)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    command_verify_receipt "$2" "$3"
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
