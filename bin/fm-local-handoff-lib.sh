#!/usr/bin/env bash
# Record mechanics for local-only secondmate custody: the project binding a
# seed writes into a secondmate home, the head-pinned landing offer a child
# worker publishes, and the landing receipt the primary publishes back.
#
# Three durable records, each a newline list of `key=value` lines with a
# leading `schema=` and no unknown keys:
#
#   fm-local-only-binding.v1  <child-home>/data/local-only-bindings/<project>.binding
#     project parent_home parent_project seed_commit seed_branch created
#     Written by bin/fm-home-seed.sh inside the seed transaction. Its presence
#     is what makes a project in that home a BOUND local-only clone: the child
#     may not land it, and its tasks need a primary receipt before teardown.
#
#   fm-local-offer.v1         <child-home>/state/<task>.local-offer
#     secondmate child_home parent_home project child_project task spawn_gen
#     branch head bundle created
#     Written by bin/fm-local-handoff.sh offer beside a git bundle holding
#     exactly that head. Immutable: a changed head needs a NEW offer, so an
#     approval pinned to the old head can never carry over.
#
#   fm-local-receipt.v1       <child-home>/state/<task>.local-receipt
#     secondmate parent_home parent_project project task spawn_gen head
#     default_branch landed_at
#     Written by the PRIMARY after its guarded fast-forward. It is durable
#     evidence, never authority on its own: every consumer re-proves that
#     `head` is contained in the primary's own default branch before trusting
#     it, so a forged or copied receipt buys nothing.
#
# Identity is the whole point of these records, so parsing fails closed on a
# symlink, a NUL byte, a duplicate key, an unknown key, a missing required
# key, or a malformed line rather than reading around the damage.
#
# This library is mechanics only. bin/fm-local-handoff.sh owns the CLI,
# bin/fm-merge-local.sh owns the guarded primary landing, and
# .agents/skills/secondmate-provisioning/SKILL.md owns the operating contract.

FM_LOCAL_HANDOFF_ERROR=
# Every loader below reports its record through this global rather than on
# stdout. A `blob=$(..._load ...)` would run the loader in a subshell, so the
# refusal reason it wrote to FM_LOCAL_HANDOFF_ERROR would die with that
# subshell and the caller would print an empty reason for a fail-closed
# refusal. Call the loader directly, then copy this into a local.
FM_LOCAL_HANDOFF_RECORD=

FM_LOCAL_HANDOFF_BINDING_SCHEMA=fm-local-only-binding.v1
FM_LOCAL_HANDOFF_OFFER_SCHEMA=fm-local-offer.v1
FM_LOCAL_HANDOFF_RECEIPT_SCHEMA=fm-local-receipt.v1

FM_LOCAL_HANDOFF_BINDING_KEYS='project parent_home parent_project seed_commit seed_branch created'
FM_LOCAL_HANDOFF_OFFER_KEYS='secondmate child_home parent_home project child_project task spawn_gen branch head bundle created'
FM_LOCAL_HANDOFF_RECEIPT_KEYS='secondmate parent_home parent_project project task spawn_gen head default_branch landed_at'

# Child identity and registry routing have owners already; the identity proof
# below reads them through those owners rather than re-parsing either format.
# shellcheck source=bin/fm-secondmate-parent-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-registry-lib.sh"

# --- value validators -------------------------------------------------------

fm_local_handoff_valid_sha() {
  local value=$1
  [ "${#value}" -eq 40 ] || return 1
  case "$value" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

# A privacy-safe slug usable as a task id, secondmate id, or project directory
# name: no separators, no relative-path meaning, no leading dash.
fm_local_handoff_valid_slug() {
  local value=$1
  case "$value" in
    ''|.|..) return 1 ;;
    -*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# An absolute path with no traversal or empty component, so a record can never
# name a directory by walking out of the one it claims.
fm_local_handoff_valid_abs() {
  local value=$1
  case "$value" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$value" in
    */) return 1 ;;
    *//*|*/./*|*/../*|*/.|*/..) return 1 ;;
  esac
}

fm_local_handoff_valid_epoch() {
  local value=$1
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

# --- record paths -----------------------------------------------------------

fm_local_handoff_binding_dir() {  # <child-home>
  printf '%s\n' "${1%/}/data/local-only-bindings"
}

fm_local_handoff_binding_path() {  # <child-home> <project>
  printf '%s/%s.binding\n' "$(fm_local_handoff_binding_dir "$1")" "$2"
}

fm_local_handoff_offer_path() {  # <child-state-dir> <task>
  printf '%s/%s.local-offer\n' "${1%/}" "$2"
}

fm_local_handoff_bundle_path() {  # <child-state-dir> <task>
  printf '%s/%s.local-offer.bundle\n' "${1%/}" "$2"
}

fm_local_handoff_receipt_path() {  # <child-state-dir> <task>
  printf '%s/%s.local-receipt\n' "${1%/}" "$2"
}

# --- record read/write ------------------------------------------------------

fm_local_handoff__key_listed() {  # <key> <space-separated-list>
  local key=$1 listed
  for listed in $2; do
    [ "$listed" = "$key" ] && return 0
  done
  return 1
}

# Load <file> as a <schema> record whose keys are drawn from <allowed> and
# which carries every key in <required> non-empty. Prints the validated
# `key=value` blob on stdout; the caller keeps it in a local and reads fields
# with fm_local_handoff_field, so nested parses never clobber each other.
fm_local_handoff_record_load() {  # <file> <schema> <allowed> <required>
  local file=$1 schema=$2 allowed=$3 required=$4
  local line key value seen='' blob='' schema_seen=0 bytes stripped

  FM_LOCAL_HANDOFF_ERROR=
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    FM_LOCAL_HANDOFF_ERROR="record is missing or not an ordinary file: $file"
    return 1
  fi
  # bash's read drops NUL bytes and different bash generations splice the
  # surrounding bytes differently, so a NUL-bearing record can resolve to a
  # path its bytes never name contiguously. Reject the whole record first.
  bytes=$(wc -c < "$file") || { FM_LOCAL_HANDOFF_ERROR="record cannot be read: $file"; return 1; }
  stripped=$(LC_ALL=C tr -d '\0' < "$file" | wc -c) || { FM_LOCAL_HANDOFF_ERROR="record cannot be read: $file"; return 1; }
  if [ "$bytes" -ne "$stripped" ]; then
    FM_LOCAL_HANDOFF_ERROR="record contains NUL bytes: $file"
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      *=*) ;;
      *) FM_LOCAL_HANDOFF_ERROR="record line is not key=value: $file"; return 1 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      ''|*[!a-z_]*) FM_LOCAL_HANDOFF_ERROR="record key is malformed: $file"; return 1 ;;
    esac
    if fm_local_handoff__key_listed "$key" "$seen"; then
      FM_LOCAL_HANDOFF_ERROR="record repeats key $key: $file"
      return 1
    fi
    if [ "$key" = schema ]; then
      if [ "$value" != "$schema" ]; then
        FM_LOCAL_HANDOFF_ERROR="record is schema $value, expected $schema: $file"
        return 1
      fi
      schema_seen=1
    elif ! fm_local_handoff__key_listed "$key" "$allowed"; then
      FM_LOCAL_HANDOFF_ERROR="record carries unknown key $key: $file"
      return 1
    fi
    seen="$seen $key"
    blob="$blob$key=$value
"
  done < "$file"

  if [ "$schema_seen" -ne 1 ]; then
    FM_LOCAL_HANDOFF_ERROR="record has no schema=$schema line: $file"
    return 1
  fi
  for key in $required; do
    if ! fm_local_handoff__key_listed "$key" "$seen"; then
      FM_LOCAL_HANDOFF_ERROR="record is missing required key $key: $file"
      return 1
    fi
    value=$(fm_local_handoff_field "$blob" "$key")
    if [ -z "$value" ]; then
      FM_LOCAL_HANDOFF_ERROR="record has empty required key $key: $file"
      return 1
    fi
  done
  FM_LOCAL_HANDOFF_RECORD=$blob
}

fm_local_handoff_field() {  # <blob> <key>
  local blob=$1 key=$2 line
  while IFS= read -r line; do
    case "$line" in
      "$key"=*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done <<EOF
$blob
EOF
  return 1
}

# Publish a record atomically. The temporary sibling is replaced with mv so a
# reader never sees a half-written identity.
fm_local_handoff_write_record() {  # <path> <line>...
  local path=$1 tmp dir
  shift
  dir=$(dirname "$path")
  mkdir -p "$dir" || { FM_LOCAL_HANDOFF_ERROR="cannot create record directory: $dir"; return 1; }
  tmp="$path.tmp.$$"
  rm -f -- "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$@" > "$tmp"; then
    FM_LOCAL_HANDOFF_ERROR="cannot write record: $path"
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -f -- "$tmp" "$path"; then
    FM_LOCAL_HANDOFF_ERROR="cannot publish record: $path"
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

# --- typed loaders ----------------------------------------------------------

fm_local_handoff_binding_load() {  # <child-home> <project>
  local home=$1 project=$2 path blob
  path=$(fm_local_handoff_binding_path "$home" "$project")
  fm_local_handoff_record_load "$path" "$FM_LOCAL_HANDOFF_BINDING_SCHEMA" \
    "$FM_LOCAL_HANDOFF_BINDING_KEYS" "$FM_LOCAL_HANDOFF_BINDING_KEYS" || return 1
  blob=$FM_LOCAL_HANDOFF_RECORD
  if [ "$(fm_local_handoff_field "$blob" project)" != "$project" ]; then
    FM_LOCAL_HANDOFF_ERROR="binding at $path names a different project"
    return 1
  fi
  if ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" parent_home)" \
    || ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" parent_project)"; then
    FM_LOCAL_HANDOFF_ERROR="binding at $path has a malformed parent path"
    return 1
  fi
  if ! fm_local_handoff_valid_sha "$(fm_local_handoff_field "$blob" seed_commit)"; then
    FM_LOCAL_HANDOFF_ERROR="binding at $path has a malformed seed commit"
    return 1
  fi
  FM_LOCAL_HANDOFF_RECORD=$blob
}

# Is <project> in <home> a bound local-only clone at all? Used by call sites
# that must change behavior for a bound project but have no record to read
# yet. An unreadable or malformed binding counts as present, because the
# guarded path must fail closed rather than fall back to the unbound one.
fm_local_handoff_binding_present() {  # <child-home> <project>
  local path
  path=$(fm_local_handoff_binding_path "$1" "$2")
  [ -e "$path" ] || [ -L "$path" ]
}

fm_local_handoff_offer_load() {  # <offer-file>
  local path=$1 blob head task branch
  fm_local_handoff_record_load "$path" "$FM_LOCAL_HANDOFF_OFFER_SCHEMA" \
    "$FM_LOCAL_HANDOFF_OFFER_KEYS" "$FM_LOCAL_HANDOFF_OFFER_KEYS" || return 1
  blob=$FM_LOCAL_HANDOFF_RECORD
  head=$(fm_local_handoff_field "$blob" head)
  task=$(fm_local_handoff_field "$blob" task)
  branch=$(fm_local_handoff_field "$blob" branch)
  if ! fm_local_handoff_valid_sha "$head"; then
    FM_LOCAL_HANDOFF_ERROR="offer at $path has a malformed head"
    return 1
  fi
  if ! fm_local_handoff_valid_slug "$task" \
    || ! fm_local_handoff_valid_slug "$(fm_local_handoff_field "$blob" secondmate)" \
    || ! fm_local_handoff_valid_slug "$(fm_local_handoff_field "$blob" project)"; then
    FM_LOCAL_HANDOFF_ERROR="offer at $path has a malformed identity"
    return 1
  fi
  if [ "$branch" != "fm/$task" ]; then
    FM_LOCAL_HANDOFF_ERROR="offer at $path names branch $branch, expected fm/$task"
    return 1
  fi
  if ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" child_home)" \
    || ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" parent_home)" \
    || ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" child_project)" \
    || ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" bundle)"; then
    FM_LOCAL_HANDOFF_ERROR="offer at $path has a malformed path"
    return 1
  fi
  FM_LOCAL_HANDOFF_RECORD=$blob
}

fm_local_handoff_receipt_load() {  # <receipt-file>
  local path=$1 blob
  fm_local_handoff_record_load "$path" "$FM_LOCAL_HANDOFF_RECEIPT_SCHEMA" \
    "$FM_LOCAL_HANDOFF_RECEIPT_KEYS" "$FM_LOCAL_HANDOFF_RECEIPT_KEYS" || return 1
  blob=$FM_LOCAL_HANDOFF_RECORD
  if ! fm_local_handoff_valid_sha "$(fm_local_handoff_field "$blob" head)"; then
    FM_LOCAL_HANDOFF_ERROR="receipt at $path has a malformed head"
    return 1
  fi
  if ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" parent_home)" \
    || ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" parent_project)"; then
    FM_LOCAL_HANDOFF_ERROR="receipt at $path has a malformed parent path"
    return 1
  fi
  FM_LOCAL_HANDOFF_RECORD=$blob
}

# --- shared checks ----------------------------------------------------------

# The single owner of "which branch is this clone's default": origin/HEAD when
# the clone has one, else main or master. bin/fm-merge-local.sh lands onto the
# branch this names, and every containment proof below asks the same question
# the same way.
fm_local_handoff_default_branch() {  # <repo>
  local repo=$1 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# The one containment proof every receipt consumer must re-run: is <head>
# genuinely reachable from <repo>'s default branch right now? A receipt that
# says so proves nothing by itself.
fm_local_handoff_head_in_default() {  # <repo> <head> [expected-default-branch]
  local repo=$1 head=$2 expected=${3:-} default
  FM_LOCAL_HANDOFF_ERROR=
  if [ ! -d "$repo" ]; then
    FM_LOCAL_HANDOFF_ERROR="primary clone is not present at $repo"
    return 1
  fi
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    FM_LOCAL_HANDOFF_ERROR="primary clone at $repo is not a git repository"
    return 1
  fi
  if ! default=$(fm_local_handoff_default_branch "$repo"); then
    FM_LOCAL_HANDOFF_ERROR="cannot determine the default branch of $repo"
    return 1
  fi
  if [ -n "$expected" ] && [ "$expected" != "$default" ]; then
    FM_LOCAL_HANDOFF_ERROR="primary clone $repo is now on default branch $default, not the recorded $expected"
    return 1
  fi
  if ! git -C "$repo" rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1; then
    FM_LOCAL_HANDOFF_ERROR="commit $head is not present in $repo"
    return 1
  fi
  if ! git -C "$repo" merge-base --is-ancestor "$head" "refs/heads/$default" 2>/dev/null; then
    FM_LOCAL_HANDOFF_ERROR="commit $head is not contained in $default of $repo"
    return 1
  fi
}

# Validate a receipt against the offer it must answer, then re-prove
# containment in the primary clone the receipt names. This is the complete
# "may the child task be torn down" test; a child-local merge or a pushed
# remote never reaches it.
fm_local_handoff_receipt_proves() {  # <receipt-file> <offer-blob>
  local receipt_file=$1 offer_blob=$2 receipt_blob key offer_value receipt_value

  fm_local_handoff_receipt_load "$receipt_file" || return 1
  receipt_blob=$FM_LOCAL_HANDOFF_RECORD
  for key in secondmate parent_home project task spawn_gen head; do
    offer_value=$(fm_local_handoff_field "$offer_blob" "$key")
    receipt_value=$(fm_local_handoff_field "$receipt_blob" "$key")
    if [ "$offer_value" != "$receipt_value" ]; then
      FM_LOCAL_HANDOFF_ERROR="receipt $key is $receipt_value but the offer says $offer_value"
      return 1
    fi
  done
  fm_local_handoff_head_in_default \
    "$(fm_local_handoff_field "$receipt_blob" parent_project)" \
    "$(fm_local_handoff_field "$receipt_blob" head)" \
    "$(fm_local_handoff_field "$receipt_blob" default_branch)" || return 1
  FM_LOCAL_HANDOFF_RECORD=$receipt_blob
}

# --- primary-side identity proof --------------------------------------------

# Prove that an offer still describes the SAME child, parent, project, task
# incarnation and commit it was published for, from the live records on both
# sides. Every landing and every receipt recovery runs this before touching a
# repository, so a stale offer, a re-registered route, a re-seeded binding, a
# respawned child task, or a moved branch head refuses instead of landing
# something the approval never named.
#
# Args: <offer-blob> <parent-home> <parent-data-dir> <parent-projects-dir>
# The caller supplies the parent identity from its own environment rather than
# from the record, so a record can never nominate the home that validates it.
fm_local_handoff_offer_identity_proves() {
  local blob=$1 parent_home=$2 parent_data=$3 parent_projects=$4
  local secondmate child_home project task spawn_gen head branch child_project bundle
  local marker_id child_project_now parent_project meta binding registered_home
  local bundle_refs expected_ref

  FM_LOCAL_HANDOFF_ERROR=
  secondmate=$(fm_local_handoff_field "$blob" secondmate)
  child_home=$(fm_local_handoff_field "$blob" child_home)
  project=$(fm_local_handoff_field "$blob" project)
  task=$(fm_local_handoff_field "$blob" task)
  spawn_gen=$(fm_local_handoff_field "$blob" spawn_gen)
  head=$(fm_local_handoff_field "$blob" head)
  branch=$(fm_local_handoff_field "$blob" branch)
  child_project=$(fm_local_handoff_field "$blob" child_project)
  bundle=$(fm_local_handoff_field "$blob" bundle)
  parent_project="${parent_projects%/}/$project"

  if [ "$(fm_local_handoff_field "$blob" parent_home)" != "$parent_home" ]; then
    FM_LOCAL_HANDOFF_ERROR="offer names parent home $(fm_local_handoff_field "$blob" parent_home), not this home $parent_home"
    return 1
  fi

  # The child home must still claim this secondmate identity and this parent.
  if [ ! -f "$child_home/.fm-secondmate-home" ] || [ -L "$child_home/.fm-secondmate-home" ]; then
    FM_LOCAL_HANDOFF_ERROR="child home $child_home is not a seeded secondmate home"
    return 1
  fi
  marker_id=$(head -1 "$child_home/.fm-secondmate-home" 2>/dev/null || true)
  if [ "$marker_id" != "$secondmate" ]; then
    FM_LOCAL_HANDOFF_ERROR="child home $child_home is marked for ${marker_id:-unknown}, not $secondmate"
    return 1
  fi
  if ! fm_secondmate_parent_record_parse "$child_home/.fm-secondmate-parent"; then
    FM_LOCAL_HANDOFF_ERROR="child home $child_home has no readable parent binding"
    return 1
  fi
  if [ "$FM_SECONDMATE_PARENT_ROUTE" != local ] || [ "$FM_SECONDMATE_PARENT_HOME" != "$parent_home" ]; then
    FM_LOCAL_HANDOFF_ERROR="child home $child_home is no longer bound to this home by a local route"
    return 1
  fi

  # The registry must still route this secondmate to this home. A re-registered
  # route means the offer belongs to a placement that no longer exists.
  if ! secondmate_registry_line_for_id "${parent_data%/}/secondmates.md" "$secondmate"; then
    FM_LOCAL_HANDOFF_ERROR="secondmate $secondmate has no single registry entry in this home"
    return 1
  fi
  if [ "$SECONDMATE_REGISTRY_REMOTE" != 0 ]; then
    FM_LOCAL_HANDOFF_ERROR="secondmate $secondmate is registered on a remote route; local-only custody is local-placement only"
    return 1
  fi
  registered_home=$(secondmate_registry_path_key "$SECONDMATE_REGISTRY_HOME" 2>/dev/null || true)
  if [ "$registered_home" != "$child_home" ]; then
    FM_LOCAL_HANDOFF_ERROR="secondmate $secondmate is now registered at ${registered_home:-an unreadable home}, not $child_home"
    return 1
  fi

  # The project must still be bound to THIS parent's clone of THIS project.
  fm_local_handoff_binding_load "$child_home" "$project" || return 1
  binding=$FM_LOCAL_HANDOFF_RECORD
  if [ "$(fm_local_handoff_field "$binding" parent_home)" != "$parent_home" ] \
    || [ "$(fm_local_handoff_field "$binding" parent_project)" != "$parent_project" ]; then
    FM_LOCAL_HANDOFF_ERROR="project $project in $child_home is bound to a different parent clone"
    return 1
  fi

  # The child task must still be the same local-only incarnation.
  meta="$child_home/state/$task.meta"
  if [ ! -f "$meta" ]; then
    FM_LOCAL_HANDOFF_ERROR="child task $task has no record at $meta"
    return 1
  fi
  if [ "$(grep '^mode=' "$meta" 2>/dev/null | head -1 | cut -d= -f2-)" != local-only ]; then
    FM_LOCAL_HANDOFF_ERROR="child task $task is no longer mode=local-only"
    return 1
  fi
  local meta_gen
  meta_gen=$(grep '^spawn_gen=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)
  [ -n "$meta_gen" ] || meta_gen=0
  if [ "$meta_gen" != "$spawn_gen" ]; then
    FM_LOCAL_HANDOFF_ERROR="child task $task is now incarnation $meta_gen, not the offered $spawn_gen"
    return 1
  fi
  child_project_now=$(grep '^project=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)
  if [ "$(basename "${child_project_now:-}")" != "$project" ]; then
    FM_LOCAL_HANDOFF_ERROR="child task $task now records project $(basename "${child_project_now:-unknown}"), not $project"
    return 1
  fi

  # The offered commit must still be exactly what the child branch points at.
  if [ ! -d "$child_project" ]; then
    FM_LOCAL_HANDOFF_ERROR="child clone $child_project is not present"
    return 1
  fi
  if [ "$(git -C "$child_project" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null || true)" != "$head" ]; then
    FM_LOCAL_HANDOFF_ERROR="child branch $branch no longer points at the offered head $head"
    return 1
  fi

  # The bundle must carry exactly the offered head under exactly the offered
  # ref, so importing it can introduce nothing the offer did not name.
  if [ ! -f "$bundle" ] || [ -L "$bundle" ]; then
    FM_LOCAL_HANDOFF_ERROR="offer bundle is missing or not an ordinary file: $bundle"
    return 1
  fi
  if ! git -C "$child_project" bundle verify "$bundle" >/dev/null 2>&1; then
    FM_LOCAL_HANDOFF_ERROR="offer bundle does not verify: $bundle"
    return 1
  fi
  bundle_refs=$(git -C "$child_project" bundle list-heads "$bundle" 2>/dev/null || true)
  expected_ref="$head refs/heads/$branch"
  if [ "$bundle_refs" != "$expected_ref" ]; then
    FM_LOCAL_HANDOFF_ERROR="offer bundle does not hold exactly $expected_ref"
    return 1
  fi
}

# Publish the landing receipt for <offer-blob> into the child home. Shared by
# the guarded landing and its recovery retry so both write the same identity.
fm_local_handoff_publish_receipt() {  # <offer-blob> <parent-project>
  local blob=$1 parent_project=$2 child_home task default
  child_home=$(fm_local_handoff_field "$blob" child_home)
  task=$(fm_local_handoff_field "$blob" task)
  if ! default=$(fm_local_handoff_default_branch "$parent_project"); then
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_LOCAL_HANDOFF_ERROR="cannot determine the default branch of $parent_project"
    return 1
  fi
  fm_local_handoff_write_record "$(fm_local_handoff_receipt_path "${child_home%/}/state" "$task")" \
    "schema=$FM_LOCAL_HANDOFF_RECEIPT_SCHEMA" \
    "secondmate=$(fm_local_handoff_field "$blob" secondmate)" \
    "parent_home=$(fm_local_handoff_field "$blob" parent_home)" \
    "parent_project=$parent_project" \
    "project=$(fm_local_handoff_field "$blob" project)" \
    "task=$task" \
    "spawn_gen=$(fm_local_handoff_field "$blob" spawn_gen)" \
    "head=$(fm_local_handoff_field "$blob" head)" \
    "default_branch=$default" \
    "landed_at=$(date +%s)"
}
