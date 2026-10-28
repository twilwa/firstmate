# shellcheck shell=bash
# Retire this task's process-event registrations before destructive teardown.
# The retire command owns locking, owner revalidation, runner identity and
# pending-round checks. A refusal must leave the durable task record available.

teardown_retire_process_events() {  # <state> <task-id> <script-dir>
  local state=$1 task=$2 scripts=$3 reg rec id kind owner reason
  reg="$state/procevent"
  [ -e "$reg" ] || [ -L "$reg" ] || return 0
  if [ ! -d "$reg" ] || [ -L "$reg" ]; then
    echo "error: cannot enumerate process-event sources for task $task: unsafe registry $reg" >&2
    return 1
  fi
  for rec in "$reg"/*.source; do
    [ -e "$rec" ] || [ -L "$rec" ] || continue
    id=${rec##*/}; id=${id%.source}
    if [ ! -f "$rec" ] || [ -L "$rec" ] || ! {
      IFS= read -r _ && IFS= read -r kind && IFS= read -r owner
    } < "$rec"; then
      echo "error: cannot determine process-event source $id ownership; retaining task $task" >&2
      return 1
    fi
    [ "$kind" = kind=task-owned ] && [ "$owner" = "owner_task=$task" ] || continue
    if ! reason=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" "$scripts/fm-procevent.sh" retire "$id" --if-owner "$task" 2>&1); then
      printf 'error: cannot retire process-event source %s for task %s; retaining task record: %s\n' \
        "$id" "$task" "$reason" >&2
      return 1
    fi
  done
}
