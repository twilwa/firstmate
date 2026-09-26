#!/usr/bin/env bash
# Conservative pane fallback for a worker's final assistant text. A fenced or
# quoted question and an echoed status line are evidence, not an assistant ask.
# The transcript is split from the harness's prompt and footer rows by the
# composer owner's prompt detection (bin/fm-composer-lib.sh); a pane it cannot
# split yields no question. No backend-specific UI strings are interpreted here.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"

fm_pane_question_text() {  # <capture>
  local transcript
  transcript=$(fm_composer_transcript_above "$1") || return 0
  printf '%s\n' "$transcript" | awk '
    BEGIN { brk = 1 }
    /^[[:space:]]*```/ { fence = !fence; brk = 1; next }
    fence || /^[[:space:]]*(>|\||[[:alnum:]_-]+[[:space:]]*\[.*\]:)/ \
      || /^[[:space:]]*["\047].*["\047][[:space:]]*$/ \
      || /^[[:space:]]*(needs-decision|blocked|working|done|resolved|failed|paused)[[:space:]]*(\[.*\])?:/ \
      || /^[[:space:]]*$/ { brk = 1; next }
    { if (brk) first = $0; brk = 0; last = $0 }
    END {
      if (last ~ /(needs-decision|blocked)[[:space:]]*\[key=[^]]+\]:/) exit
      gsub(/`[^`]*`/, "", last)
      sub(/[[:space:]]+$/, "", last)
      sub(/^[[:space:]]*([^[:alnum:][:space:]]+[[:space:]]+)?/, "", first)
      if (last ~ /\?$/ || tolower(first) ~ /^captain,/) print (last != "" ? last : first)
    }
  '
}

# The marker is the last observed turn signature, status byte position, and the
# status size at the last published question. It advances only after the wake
# and durable nudge have been queued. Same-marker polls cannot repeat either
# publication, even after watcher restart, and a later question turn publishes
# again only once the status file has moved off the published size.
fm_pane_question_turn() {  # <state> <task> <turn-signature> <capture>
  local state=$1 task=$2 sig=$3 capture=$4 marker prev='' prior=0 nudged='' size=0 text line verb
  marker="$state/.pane-question-$task"
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    IFS=$(printf '\t') read -r prev prior nudged < "$marker" || true
  fi
  [ "$prev" != "$sig" ] || return 1
  case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
  if [ -f "$state/$task.status" ] && [ ! -L "$state/$task.status" ]; then
    size=$(LC_ALL=C wc -c < "$state/$task.status") || return 1
    size=${size//[[:space:]]/}
    [ "$prior" -le "$size" ] || prior=0
    if [ "$size" -gt "$prior" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          needs-decision\ *|blocked\ *)
            case "$line" in *'[key='*']'*)
              printf '%s\t%s\t%s\n' "$sig" "$size" "$nudged" > "$marker"
              return 1 ;;
            esac ;;
        esac
      done < <(LC_ALL=C tail -c "+$((prior + 1))" "$state/$task.status")
    fi
  fi
  text=''
  [ "$nudged" = "$size" ] || text=$(fm_pane_question_text "$capture")
  [ -n "$text" ] || { printf '%s\t%s\t%s\n' "$sig" "$size" "$nudged" > "$marker"; return 1; }
  FM_PANE_QUESTION_SIZE=$size
  return 0
}
