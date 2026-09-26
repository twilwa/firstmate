#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns, or
# when a delegated landing has published its receipt;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
#
# Usage:
#   fm-merge-local.sh <task-id>
#       Land this home's own local-only ship task from its fm/<task-id> branch.
#
#   fm-merge-local.sh <landing-id> --offer <offer-file> --expect-head <sha>
#       Land the pinned offer a local-only secondmate child published for one of
#       its tasks. This is the same guard, not a second landing system: the
#       authority is still a captain-held backlog row, here the row named by
#       <landing-id>, whose parent-owned landing record must already pin this
#       exact offer through bin/fm-local-handoff.sh request, and the pinned
#       <sha> is the exact head that approval named. No worker record is read, written, or invented for the
#       child; its identity comes from its own offer, re-proved against both
#       homes' live records under this home's lock. The offered commit arrives
#       through the offer's git bundle into a private import ref - never a
#       remote, a forge, or shared object storage - and the fast-forward is
#       followed by a durable landing receipt in the child home, which is the
#       only thing that later permits that child task's ordinary teardown, and
#       only then by closing the landing row <landing-id>.
#       A landing whose receipt cannot be published reports the work as landed
#       but unacknowledged and names the idempotent recovery command; it never
#       reports success.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-local-handoff-lib.sh
. "$SCRIPT_DIR/fm-local-handoff-lib.sh"
if [ "$#" -lt 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
shift
OFFER_FILE=
EXPECT_HEAD=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --offer)
      [ "$#" -ge 2 ] || { echo "error: --offer needs the child's offer file" >&2; exit 2; }
      OFFER_FILE=$2
      shift 2
      ;;
    --expect-head)
      [ "$#" -ge 2 ] || { echo "error: --expect-head needs the approved commit" >&2; exit 2; }
      EXPECT_HEAD=$2
      shift 2
      ;;
    *)
      echo "error: unknown local merge option $1" >&2
      exit 2
      ;;
  esac
done
DELEGATED=0
if [ -n "$OFFER_FILE" ] || [ -n "$EXPECT_HEAD" ]; then
  DELEGATED=1
  if [ -z "$OFFER_FILE" ] || [ -z "$EXPECT_HEAD" ]; then
    echo "error: a delegated landing needs both --offer and --expect-head, because the approval is pinned to one exact commit" >&2
    exit 2
  fi
fi
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

MERGE_EXPECTED_SPAWN_GEN=
if [ "$DELEGATED" -eq 1 ]; then
  # A delegated landing has no worker of its own and never fabricates one. Its
  # authority is the parent-owned backlog row $ID that the captain-hold check
  # below reads; the child's incarnation is carried by the offer and re-proved
  # against the child's own record.
  if [ -e "$META" ]; then
    echo "error: $ID has a worker record at $META; a delegated landing takes the parent-owned landing record id, not a task id" >&2
    exit 1
  fi
else
  [ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
  if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
    echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  fi
  MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN
fi

MERGE_CONTROL_LOCK=
IMPORT_REF=
merge_control_cleanup() {
  [ -z "$IMPORT_REF" ] || git -C "$PROJ" update-ref -d "$IMPORT_REF" >/dev/null 2>&1 || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if [ "$DELEGATED" -eq 0 ]; then
  if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
    echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  fi
  if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
    echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
    exit 1
  fi
fi

PARENT_HOME=$(cd "$FM_HOME" && pwd -P)
OFFER_BLOB=
LANDING_BLOB=
if [ "$DELEGATED" -eq 1 ]; then
  [ -d "$PROJECTS" ] || { echo "error: projects directory $PROJECTS is not present" >&2; exit 1; }
  PROJECTS_ABS=$(cd "$PROJECTS" && pwd -P)
  fm_local_handoff_valid_sha "$EXPECT_HEAD" || { echo "error: --expect-head must be a full commit id" >&2; exit 1; }
  fm_local_handoff_offer_load "$OFFER_FILE" || { echo "error: $FM_LOCAL_HANDOFF_ERROR" >&2; exit 1; }
  OFFER_BLOB=$FM_LOCAL_HANDOFF_RECORD
  OFFER_HEAD=$(fm_local_handoff_field "$OFFER_BLOB" head)
  if [ "$OFFER_HEAD" != "$EXPECT_HEAD" ]; then
    echo "error: the offer at $OFFER_FILE is at $OFFER_HEAD, not the approved $EXPECT_HEAD; a moved head needs its own approval" >&2
    exit 1
  fi
  # Re-proved here, under the lock, rather than at approval time: a re-seeded
  # binding, a re-registered route, a respawned child task or a moved branch
  # between approval and landing must refuse, not land.
  if ! fm_local_handoff_offer_identity_proves "$OFFER_BLOB" "$PARENT_HOME" "$DATA" "$PROJECTS_ABS"; then
    echo "error: $FM_LOCAL_HANDOFF_ERROR" >&2
    exit 1
  fi
  PROJECT_NAME=$(fm_local_handoff_field "$OFFER_BLOB" project)
  PROJ="$PROJECTS_ABS/$PROJECT_NAME"
  CHILD_TASK=$(fm_local_handoff_field "$OFFER_BLOB" task)
  # Custody does not chain: a home whose own clone is a bound child copy is not
  # the primary for anything, so it may not accept a delegated landing either.
  if fm_local_handoff_binding_present "$PARENT_HOME" "$PROJECT_NAME"; then
    echo "error: this home's clone of $PROJECT_NAME is itself a bound local-only copy; only the home that seeded it lands its work" >&2
    exit 1
  fi
  # The project's registered delivery posture is re-read here rather than
  # trusted from seed time: a project moved off local-only is landed through
  # its forge path, and a bundle import into it would be a route change the
  # captain never approved.
  if ! fm_local_handoff_project_still_local_only "$SCRIPT_DIR" "$FM_HOME" "$DATA" "$PROJECT_NAME"; then
    echo "error: $FM_LOCAL_HANDOFF_ERROR" >&2
    exit 1
  fi
  # The approval itself is the captain-held row $ID checked below. This is the
  # parent-owned record that binds that one pending call to this exact offer,
  # written by bin/fm-local-handoff.sh request while the row was still held, so
  # a release recorded for one head can never be inherited by a later one.
  if ! fm_local_handoff_landing_load "$DATA" "$ID"; then
    echo "error: $FM_LOCAL_HANDOFF_ERROR" >&2
    echo "Pin the approved offer with bin/fm-local-handoff.sh request $ID --offer $OFFER_FILE while the row is still held." >&2
    exit 1
  fi
  LANDING_BLOB=$FM_LOCAL_HANDOFF_RECORD
  if [ "$(fm_local_handoff_field "$LANDING_BLOB" state)" = landed ]; then
    echo "error: landing record $ID already recorded $(fm_local_handoff_field "$LANDING_BLOB" head) as landed; further work needs its own held row and its own pinned offer" >&2
    exit 1
  fi
  if ! fm_local_handoff_landing_matches_offer "$LANDING_BLOB" "$OFFER_BLOB" "$PARENT_HOME" "$PROJ"; then
    echo "error: $FM_LOCAL_HANDOFF_ERROR" >&2
    exit 1
  fi
else
  PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
  MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
  [ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge GitHub PR tasks with bin/fm-pr-review.sh merge <id> <PR url> when the review policy requires the reviewed-head handoff and bin/fm-pr-merge.sh <id> <PR url> otherwise, or GitLab MR tasks with bin/fm-pr-merge.sh <id> <MR url>, after approval" >&2; exit 1; }
  PROJECT_NAME=$(basename "$PROJ")
  # A bound local-only clone is a CHILD copy of someone else's project. Landing
  # it here would produce a merge no receipt can ever prove, and teardown would
  # then have nothing durable to check, so this refuses and names the path that
  # does work.
  if fm_local_handoff_binding_present "$PARENT_HOME" "$PROJECT_NAME"; then
    echo "error: project $PROJECT_NAME in this home is a bound local-only clone; publish the work with bin/fm-local-handoff.sh offer $ID and have the parent land it" >&2
    exit 1
  fi
fi

if [ "$DELEGATED" -eq 1 ]; then
  # Import the offered commit from the offer's own bundle. A bundle is a file,
  # so this adds no remote, contacts no forge, and shares no object storage; a
  # stale import ref from an earlier attempt is dropped first so nothing is
  # forced and the fetched result can be compared against the pinned head.
  IMPORT_REF="refs/fm-local-handoff/$(fm_local_handoff_field "$OFFER_BLOB" secondmate)/$CHILD_TASK"
  git -C "$PROJ" update-ref -d "$IMPORT_REF" >/dev/null 2>&1 || true
  if ! git -C "$PROJ" fetch --no-tags --quiet \
    "$(fm_local_handoff_field "$OFFER_BLOB" bundle)" \
    "refs/heads/$(fm_local_handoff_field "$OFFER_BLOB" branch):$IMPORT_REF"; then
    echo "error: could not import the offered commit from the offer's bundle into $PROJ" >&2
    exit 1
  fi
  IMPORTED=$(git -C "$PROJ" rev-parse --verify --quiet "$IMPORT_REF" 2>/dev/null || true)
  if [ "$IMPORTED" != "$EXPECT_HEAD" ]; then
    echo "error: the imported bundle left ${IMPORTED:-no commit} in $PROJ, not the approved $EXPECT_HEAD" >&2
    exit 1
  fi
  BRANCH=$(fm_local_handoff_field "$OFFER_BLOB" branch)
  MERGE_TARGET=$EXPECT_HEAD
else
  BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
  [ -n "$BRANCH" ] || BRANCH="fm/$ID"
  if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
    echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
    exit 1
  fi
  git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }
  MERGE_TARGET=$BRANCH
fi

DEFAULT=$(fm_local_handoff_default_branch "$PROJ") || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$MERGE_TARGET"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
if [ "$DELEGATED" -eq 1 ]; then
  if ! fm_local_handoff_landing_released_identity "$SCRIPT_DIR" "$FM_HOME" "$STATE" "$ID" "$LANDING_BLOB"; then
    echo "error: $FM_LOCAL_HANDOFF_ERROR; refusing to merge" >&2
    exit 1
  fi
else
  hold_status=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
  case "$hold_status" in
    0)
      echo "error: task $ID is still held for the captain; release it before merging" >&2
      exit 1
      ;;
    1|3) ;;
    *)
      echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
      exit 1
      ;;
  esac
fi
merge_status=0
git -C "$PROJ" merge --ff-only "$MERGE_TARGET" >/dev/null || merge_status=$?
if [ "$DELEGATED" -eq 0 ]; then
  fm_lock_release "$MERGE_CONTROL_LOCK" || true
  MERGE_CONTROL_LOCK=
fi
if [ "$merge_status" -ne 0 ]; then
  exit "$merge_status"
fi
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true

if [ "$DELEGATED" -eq 1 ]; then
  # The receipt is a plain record written into the child home's state
  # directory. It deliberately takes no lock in that home, because this path
  # already holds this home's landing lock and waiting on another home's lock
  # from here is what would deadlock the fleet.
  landing_failure=
  if ! fm_local_handoff_landing_publish "$DATA" "$LANDING_BLOB" "$ID" \
    "$(fm_local_handoff_field "$LANDING_BLOB" offer)" "$PROJ" landed "$(date +%s)"; then
    landing_failure="its landing record could not be completed"
  elif ! fm_local_handoff_publish_receipt "$OFFER_BLOB" "$PROJ" "$ID"; then
    landing_failure="its landing receipt could not be published"
  elif ! fm_local_handoff_landing_row_close "$DATA" "$ID"; then
    landing_failure="its landing row could not be closed"
  fi
  if [ -n "$landing_failure" ]; then
    echo "error: $CHILD_TASK landed in $DEFAULT ($before -> $after) but $landing_failure: $FM_LOCAL_HANDOFF_ERROR" >&2
    echo "The work is landed and nothing is lost. Finish acknowledging it with bin/fm-local-handoff.sh receipt $OFFER_FILE --landing $ID, which is safe to repeat, and do not tear the child task down until it succeeds." >&2
    exit 1
  fi
  echo "landed $CHILD_TASK at $EXPECT_HEAD into local $DEFAULT ($before -> $after) in $PROJ"
  echo "receipt=$(fm_local_handoff_receipt_path "$(fm_local_handoff_field "$OFFER_BLOB" child_home)/state" "$CHILD_TASK")"
else
  echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
fi
