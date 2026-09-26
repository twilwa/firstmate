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
#   fm-local-landing.v2       <parent-home>/data/local-only-landings/<id>.landing
#     landing_id secondmate parent_home parent_project project task spawn_gen
#     head offer state landed_at
#     Written by bin/fm-local-handoff.sh request in the PRIMARY home while the
#     landing row <id> is still held for the captain, so the approval the
#     captain then releases is durably bound to ONE exact offered commit. The
#     guarded landing refuses an absent record, a record pinned to another head
#     or identity, and a landing row that is absent rather than released, then
#     marks the record `state=landed`. That landed record is the parent's own
#     evidence of the landing and outlives the child task; the row <id> itself
#     is closed only once the child's receipt is published.
#
#   fm-local-receipt.v1       <child-home>/state/<task>.local-receipt
#     secondmate parent_home parent_project project task spawn_gen head
#     default_branch landing_id landed_at
#     Written by the PRIMARY after its guarded fast-forward. It is durable
#     evidence, never authority on its own: every consumer re-derives the
#     primary clone from the child's own seeded parent route and project
#     binding, re-reads the parent's landing record, and re-proves that `head`
#     is contained in that clone's default branch, so a forged or copied
#     receipt - including one naming the child's own clone - buys nothing.
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
FM_LOCAL_HANDOFF_LANDING_SCHEMA=fm-local-landing.v2
FM_LOCAL_HANDOFF_RECEIPT_SCHEMA=fm-local-receipt.v1

FM_LOCAL_HANDOFF_BINDING_KEYS='project parent_home parent_project seed_commit seed_branch created'
FM_LOCAL_HANDOFF_OFFER_KEYS='secondmate child_home parent_home project child_project task spawn_gen branch head bundle created'
FM_LOCAL_HANDOFF_LANDING_KEYS='landing_id secondmate parent_home parent_project project task spawn_gen head offer hold_identity state landed_at'
FM_LOCAL_HANDOFF_RECEIPT_KEYS='secondmate parent_home parent_project project task spawn_gen head default_branch landing_id landed_at'

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

# A captain call's hold-set stamp and answer count, as emitted by the hold
# owner. Keep the count bounded for safe arithmetic when verifying release.
fm_local_handoff_valid_hold_identity() {
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?#(0|[1-9][0-9]{0,8})$ ]]
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

# The parent's landing records sit beside its other durable fleet records. The
# child side resolves this directory from the parent home its own seeded route
# marker names, never from a path a record nominated, so a parent running with
# its data directory pointed elsewhere refuses rather than being believed.
fm_local_handoff_landing_dir() {  # <parent-data-dir>
  printf '%s\n' "${1%/}/local-only-landings"
}

fm_local_handoff_landing_path() {  # <parent-data-dir> <landing-id>
  printf '%s/%s.landing\n' "$(fm_local_handoff_landing_dir "$1")" "$2"
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

# Publish a record that must NOT already exist. The hard link fails with EEXIST
# instead of replacing, which is what makes a published approval immutable: two
# overlapping requests cannot overwrite each other, and a request still in
# flight when the captain answered cannot replace the record that answer was
# recorded against. FM_LOCAL_HANDOFF_RECORD_EXISTS distinguishes the lost race
# from a write that failed for any other reason.
FM_LOCAL_HANDOFF_RECORD_EXISTS=0
fm_local_handoff_write_new_record() {  # <path> <line>...
  local path=$1 tmp dir
  shift
  FM_LOCAL_HANDOFF_RECORD_EXISTS=0
  dir=$(dirname "$path")
  mkdir -p "$dir" || { FM_LOCAL_HANDOFF_ERROR="cannot create record directory: $dir"; return 1; }
  tmp="$path.tmp.$$"
  rm -f -- "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$@" > "$tmp"; then
    FM_LOCAL_HANDOFF_ERROR="cannot write record: $path"
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! ln -- "$tmp" "$path" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null || true
    if [ -e "$path" ] || [ -L "$path" ]; then
      # shellcheck disable=SC2034 # Read by sourcing callers after this refusal.
      FM_LOCAL_HANDOFF_RECORD_EXISTS=1
      FM_LOCAL_HANDOFF_ERROR="a record already exists: $path"
    else
      FM_LOCAL_HANDOFF_ERROR="cannot publish record: $path"
    fi
    return 1
  fi
  rm -f -- "$tmp" 2>/dev/null || true
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
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    FM_LOCAL_HANDOFF_ERROR="offer at $path names an invalid task branch $branch"
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

fm_local_handoff_landing_load() {  # <parent-data-dir> <landing-id>
  local data=$1 landing_id=$2 path blob state
  path=$(fm_local_handoff_landing_path "$data" "$landing_id")
  fm_local_handoff_record_load "$path" "$FM_LOCAL_HANDOFF_LANDING_SCHEMA" \
    "$FM_LOCAL_HANDOFF_LANDING_KEYS" "$FM_LOCAL_HANDOFF_LANDING_KEYS" || return 1
  blob=$FM_LOCAL_HANDOFF_RECORD
  if [ "$(fm_local_handoff_field "$blob" landing_id)" != "$landing_id" ]; then
    FM_LOCAL_HANDOFF_ERROR="landing record at $path names a different landing"
    return 1
  fi
  if ! fm_local_handoff_valid_sha "$(fm_local_handoff_field "$blob" head)"; then
    FM_LOCAL_HANDOFF_ERROR="landing record at $path has a malformed head"
    return 1
  fi
  if ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" parent_home)" \
    || ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" parent_project)" \
    || ! fm_local_handoff_valid_abs "$(fm_local_handoff_field "$blob" offer)"; then
    FM_LOCAL_HANDOFF_ERROR="landing record at $path has a malformed path"
    return 1
  fi
  if ! fm_local_handoff_valid_hold_identity "$(fm_local_handoff_field "$blob" hold_identity)"; then
    FM_LOCAL_HANDOFF_ERROR="landing record at $path has no valid captain-call identity"
    return 1
  fi
  state=$(fm_local_handoff_field "$blob" state)
  case "$state" in
    pinned|landed) ;;
    *)
      FM_LOCAL_HANDOFF_ERROR="landing record at $path is in unknown state $state"
      return 1
      ;;
  esac
  FM_LOCAL_HANDOFF_RECORD=$blob
}

# The lines of one landing record, in schema order. The pin and the landed mark
# are the same record in two states, so both writers below build it here and
# the approval's identity can never disagree with the landing's evidence.
fm_local_handoff_landing_lines() {
  # <identity-blob> <landing-id> <offer-file> <parent-project> <state> <landed-at> [hold-identity]
  local blob=$1 landing_id=$2 offer_file=$3 parent_project=$4 state=$5 landed_at=$6
  local hold_identity=${7:-$(fm_local_handoff_field "$blob" hold_identity)}
  printf '%s\n' \
    "schema=$FM_LOCAL_HANDOFF_LANDING_SCHEMA" \
    "landing_id=$landing_id" \
    "secondmate=$(fm_local_handoff_field "$blob" secondmate)" \
    "parent_home=$(fm_local_handoff_field "$blob" parent_home)" \
    "parent_project=$parent_project" \
    "project=$(fm_local_handoff_field "$blob" project)" \
    "task=$(fm_local_handoff_field "$blob" task)" \
    "spawn_gen=$(fm_local_handoff_field "$blob" spawn_gen)" \
    "head=$(fm_local_handoff_field "$blob" head)" \
    "offer=$offer_file" \
    "hold_identity=$hold_identity" \
    "state=$state" \
    "landed_at=$landed_at"
}

# Write a landing record that may already exist. This is the landing owner's
# own transition - pinned to landed, or the idempotent recovery that repeats
# it - and never the path that takes an approval.
fm_local_handoff_landing_publish() {
  # <parent-data-dir> <identity-blob> <landing-id> <offer-file> <parent-project> <state> <landed-at>
  local data=$1 blob=$2 landing_id=$3 offer_file=$4 parent_project=$5 state=$6 landed_at=$7 lines
  lines=$(fm_local_handoff_landing_lines "$blob" "$landing_id" "$offer_file" \
    "$parent_project" "$state" "$landed_at") || return 1
  local IFS=$'\n' rc
  set -f
  # shellcheck disable=SC2086 # Deliberate split of the record into its lines.
  fm_local_handoff_write_record "$(fm_local_handoff_landing_path "$data" "$landing_id")" $lines
  rc=$?
  set +f
  return "$rc"
}

# Take an approval: publish the pin only if this landing has no record at all.
# A published approval is immutable, so this never replaces one - a different
# offer takes its own landing record, and a request that lost the race learns
# it lost through FM_LOCAL_HANDOFF_RECORD_EXISTS instead of overwriting the
# record the captain is answering.
fm_local_handoff_landing_pin() {
  # <parent-data-dir> <identity-blob> <landing-id> <offer-file> <parent-project> <hold-identity>
  local data=$1 blob=$2 landing_id=$3 offer_file=$4 parent_project=$5 hold_identity=$6 lines rc
  lines=$(fm_local_handoff_landing_lines "$blob" "$landing_id" "$offer_file" \
    "$parent_project" pinned 0 "$hold_identity") || return 1
  local IFS=$'\n'
  set -f
  # shellcheck disable=SC2086 # Deliberate word split on the record's own lines.
  fm_local_handoff_write_new_record "$(fm_local_handoff_landing_path "$data" "$landing_id")" $lines
  rc=$?
  set +f
  return "$rc"
}

# Withdraw a pin this same call published, and only that. The publish-then-verify
# refusal in bin/fm-local-handoff.sh uses it when the captain's answer overtook
# the request: the bytes on disk must still be exactly the ones that call wrote,
# so a record any other writer has since touched is preserved and reported
# rather than removed.
fm_local_handoff_landing_withdraw() {
  # <parent-data-dir> <identity-blob> <landing-id> <offer-file> <parent-project> <hold-identity>
  local data=$1 blob=$2 landing_id=$3 offer_file=$4 parent_project=$5 hold_identity=$6 path lines current
  path=$(fm_local_handoff_landing_path "$data" "$landing_id")
  lines=$(fm_local_handoff_landing_lines "$blob" "$landing_id" "$offer_file" \
    "$parent_project" pinned 0 "$hold_identity") || return 1
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    FM_LOCAL_HANDOFF_ERROR="the pin at $path is no longer this request's own record"
    return 1
  fi
  current=$(cat -- "$path" 2>/dev/null) || {
    FM_LOCAL_HANDOFF_ERROR="the pin at $path could not be re-read"
    return 1
  }
  if [ "$current" != "$lines" ]; then
    FM_LOCAL_HANDOFF_ERROR="the pin at $path changed after this request published it"
    return 1
  fi
  rm -f -- "$path" || {
    FM_LOCAL_HANDOFF_ERROR="the pin at $path could not be withdrawn"
    return 1
  }
}

# The captain releases an approval for one exact offer, so anything that has
# changed since the pin - the commit, the task, its incarnation, the
# secondmate, the project, or the parent clone - means the released approval
# named something else. Refuse rather than let a later head inherit it.
fm_local_handoff_landing_matches_offer() {
  # <landing-blob> <offer-blob> <parent-home> <parent-project>
  local landing=$1 offer=$2 parent_home=$3 parent_project=$4 key pinned offered id
  id=$(fm_local_handoff_field "$landing" landing_id)
  for key in secondmate project task spawn_gen head; do
    pinned=$(fm_local_handoff_field "$landing" "$key")
    offered=$(fm_local_handoff_field "$offer" "$key")
    if [ "$pinned" != "$offered" ]; then
      FM_LOCAL_HANDOFF_ERROR="landing record $id pins $key $pinned, but this offer is $offered; a changed offer needs its own approval"
      return 1
    fi
  done
  if [ "$(fm_local_handoff_field "$landing" parent_home)" != "$parent_home" ] \
    || [ "$(fm_local_handoff_field "$landing" parent_project)" != "$parent_project" ]; then
    FM_LOCAL_HANDOFF_ERROR="landing record $id was pinned for a different parent clone"
    return 1
  fi
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

# Where does this checkout keep its objects and refs? A linked worktree
# reports its parent clone, which is exactly what the sameness test below
# needs.
fm_local_handoff__git_common_dir() {  # <repo>
  local repo=$1 dir
  [ -d "$repo" ] || return 1
  dir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$dir" ] || return 1
  case "$dir" in
    /*) ;;
    *) dir="$repo/$dir" ;;
  esac
  ( cd "$dir" 2>/dev/null && pwd -P ) || return 1
}

# Are these two paths the same repository? A receipt whose "primary clone" is
# the child's own copy would otherwise let a child-local merge prove its own
# landing, so the landed proof refuses that case outright.
fm_local_handoff_same_repository() {  # <repo-a> <repo-b>
  local a b
  a=$(fm_local_handoff__git_common_dir "$1") || return 1
  b=$(fm_local_handoff__git_common_dir "$2") || return 1
  [ "$a" = "$b" ]
}

# The registered delivery posture is the parent's own fact and can change after
# a seed. The pin and the landing both re-read it through the registry owner
# rather than trusting a binding written earlier, so a project the captain
# moved off local-only refuses instead of landing under custody it no longer
# has.
fm_local_handoff_project_still_local_only() {  # <bin-dir> <parent-home> <parent-data-dir> <project>
  local bin_dir=$1 home=$2 data=$3 project=$4 mode
  FM_LOCAL_HANDOFF_ERROR=
  mode=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    "$bin_dir/fm-project-mode.sh" "$project" 2>/dev/null | awk 'NR==1{print $1}') || mode=
  if [ "$mode" != local-only ]; then
    FM_LOCAL_HANDOFF_ERROR="project $project is registered ${mode:-unreadable} in $home, not local-only; its local-only custody ended when that changed"
    return 1
  fi
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

# The complete "has this child task's work actually landed" test, and the only
# thing that opens ordinary teardown for a bound local-only task.
#
# Nothing the child home could rewrite in its own favour is allowed to name
# the repository the proof runs against: the seeded parent route marker names
# the parent home, that home's project binding names the parent clone, and the
# parent's own landing record proves the landing. The receipt is compared
# against all three and then re-proved against the parent repository itself,
# so a forged receipt, a copied one, or one pointing at the child's own clone
# after a child-local merge all refuse.
fm_local_handoff_landed_proof() {  # <child-home> <offer-blob> <receipt-file> <child-project>
  local child_home=$1 offer_blob=$2 receipt_file=$3 child_project=$4
  local receipt_blob binding_blob landing_blob key offer_value receipt_value
  local route_home parent_project project landing_id

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
  project=$(fm_local_handoff_field "$receipt_blob" project)

  if ! fm_secondmate_parent_record_parse "${child_home%/}/.fm-secondmate-parent"; then
    FM_LOCAL_HANDOFF_ERROR="this home has no readable parent binding, so nothing can prove where its work landed"
    return 1
  fi
  if [ "$FM_SECONDMATE_PARENT_ROUTE" != local ]; then
    FM_LOCAL_HANDOFF_ERROR="local-only custody requires a local parent route; this home is route $FM_SECONDMATE_PARENT_ROUTE"
    return 1
  fi
  route_home=$FM_SECONDMATE_PARENT_HOME
  if [ "$(fm_local_handoff_field "$receipt_blob" parent_home)" != "$route_home" ]; then
    FM_LOCAL_HANDOFF_ERROR="receipt names parent home $(fm_local_handoff_field "$receipt_blob" parent_home), but this home is routed to $route_home"
    return 1
  fi

  # The parent clone is the binding's fact, not the receipt's claim.
  fm_local_handoff_binding_load "$child_home" "$project" || return 1
  binding_blob=$FM_LOCAL_HANDOFF_RECORD
  if [ "$(fm_local_handoff_field "$binding_blob" parent_home)" != "$route_home" ]; then
    FM_LOCAL_HANDOFF_ERROR="project $project is bound to a parent home this home is no longer routed to"
    return 1
  fi
  parent_project=$(fm_local_handoff_field "$binding_blob" parent_project)
  if [ "$(fm_local_handoff_field "$receipt_blob" parent_project)" != "$parent_project" ]; then
    FM_LOCAL_HANDOFF_ERROR="receipt names $(fm_local_handoff_field "$receipt_blob" parent_project) as the primary clone, but $project is bound to $parent_project"
    return 1
  fi
  if [ -n "$child_project" ] && fm_local_handoff_same_repository "$parent_project" "$child_project"; then
    FM_LOCAL_HANDOFF_ERROR="the bound parent clone $parent_project is this task's own copy, so nothing here can prove the work reached the parent"
    return 1
  fi

  # The parent's own landing record is the evidence the child cannot write.
  landing_id=$(fm_local_handoff_field "$receipt_blob" landing_id)
  fm_local_handoff_landing_load "${route_home%/}/data" "$landing_id" || return 1
  landing_blob=$FM_LOCAL_HANDOFF_RECORD
  if [ "$(fm_local_handoff_field "$landing_blob" state)" != landed ]; then
    FM_LOCAL_HANDOFF_ERROR="landing record $landing_id in $route_home is still $(fm_local_handoff_field "$landing_blob" state), so the parent has not recorded this landing"
    return 1
  fi
  fm_local_handoff_landing_matches_offer "$landing_blob" "$offer_blob" \
    "$route_home" "$parent_project" || return 1

  fm_local_handoff_head_in_default \
    "$parent_project" \
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
  local meta_gen meta_branch
  meta_branch=$(grep '^branch=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)
  [ -n "$meta_branch" ] || meta_branch="fm/$task"
  if [ "$meta_branch" != "$branch" ]; then
    FM_LOCAL_HANDOFF_ERROR="child task $task now records branch $meta_branch, not the offered $branch"
    return 1
  fi
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
fm_local_handoff_publish_receipt() {  # <offer-blob> <parent-project> <landing-id>
  local blob=$1 parent_project=$2 landing_id=$3 child_home task default
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
    "landing_id=$landing_id" \
    "landed_at=$(date +%s)"
}

# Require the captain's recorded release to belong to the exact lifecycle
# captured at pin time. The hold owner prints the stamp and answer count for a
# released row on exit 1. The release must answer the pinned stamp and follow
# the pinned count; deferrals of that same call may precede it, while a re-held
# call is always answered under a later stamp.
fm_local_handoff_landing_released_identity() {  # <script-dir> <home> <state> <landing-id> <landing-blob>
  local script_dir=$1 home=$2 state=$3 id=$4 blob=$5 pinned current status=0
  pinned=$(fm_local_handoff_field "$blob" hold_identity)
  if ! fm_local_handoff_valid_hold_identity "$pinned"; then
    FM_LOCAL_HANDOFF_ERROR="landing $id has no valid pinned captain-call identity"
    return 1
  fi
  current=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$script_dir/fm-captain-hold.sh" open "$id" --identity \
      --identity-if-released --distinguish-absent) || status=$?
  if [ "$status" -ne 1 ]; then
    FM_LOCAL_HANDOFF_ERROR="landing $id must have a readable, released captain call (hold status $status)"
    return 1
  fi
  if ! fm_local_handoff_valid_hold_identity "$current" \
    || [ "${current%#*}" != "${pinned%#*}" ] \
    || [ "${current##*#}" -le "${pinned##*#}" ]; then
    FM_LOCAL_HANDOFF_ERROR="landing $id's captain-call lifecycle or recorded answer differs from the pinned approval"
    return 1
  fi
}

# Establish that the parent-owned landing row can still authorize recording its
# landing: the backlog shows it, and it is closed or open without being held
# for the captain again, which only the captain resolves. Receipt recovery asks
# this before it writes any landed record or receipt, so a refused recovery
# leaves nothing a later run could mistake for an acknowledged landing. Callers
# must also source bin/fm-tasks-axi-lib.sh and bin/fm-backlog-transition-lib.sh.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
fm_local_handoff_landing_row_ready() {  # <parent-data-dir> <landing-id>
  local data=$1 id=$2
  if ! fm_backlog_row_probe "$data" "$id"; then
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      FM_LOCAL_HANDOFF_ERROR="this home has no landing row $id"
    else
      FM_LOCAL_HANDOFF_ERROR="cannot read landing row $id: $FM_BACKLOG_ROW_ERROR"
    fi
    return 1
  fi
  [ "${FM_BACKLOG_ROW_STATE%% *}" != "done" ] || return 0
  if [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
    FM_LOCAL_HANDOFF_ERROR="landing row $id is held for the captain again; only bin/fm-captain-hold.sh answer resolves it"
    return 1
  fi
}

# Close the parent-owned landing row once its landing is complete: the offered
# head is in the primary's default branch, the landing record says `landed`,
# and the child's receipt is published. The close goes through the backlog
# transition owner under the same row checks as
# fm_local_handoff_landing_row_ready.
# An already closed row is left alone, which is what lets receipt recovery
# repeat. A row the backlog no longer shows is accepted only with --completed,
# which the caller passes when this landing was already fully acknowledged
# before it ran, because a closed row is later archived out of the live
# backlog.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
fm_local_handoff_landing_row_close() {  # <parent-data-dir> <landing-id> [--completed]
  local data=$1 id=$2 completed=${3:-}
  if ! fm_local_handoff_landing_row_ready "$data" "$id"; then
    if [ "$completed" = --completed ] && [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      return 0
    fi
    return 1
  fi
  [ "${FM_BACKLOG_ROW_STATE%% *}" != "done" ] || return 0
  if ! fm_backlog_done "$data" "$id" --note "local main"; then
    FM_LOCAL_HANDOFF_ERROR="cannot close landing row $id: $FM_BACKLOG_TRANSITION_ERROR"
    return 1
  fi
}
