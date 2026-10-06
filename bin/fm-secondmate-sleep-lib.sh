# shellcheck shell=bash disable=SC2034
# fm-secondmate-sleep-lib.sh - the one reader and writer of a second mate's
# durable sleep marker, state/<id>.asleep in the PARENT home. Source only.
#
# bin/fm-secondmate-sleep.sh's header owns the marker format and the sleep and
# wake transactions. Every other caller that must leave a sleeping mate alone
# asks fm_secondmate_asleep and never parses the file itself.
#
# A marker that exists but cannot be read - a symlink, a directory, an
# unreadable file - still reads as asleep, with a reason naming the unreadable
# marker, because asleep is the direction that leaves the mate alone: nothing
# relaunches, restarts, or steers it until an explicit wake removes the marker.

FM_SECONDMATE_ASLEEP_SINCE=
FM_SECONDMATE_ASLEEP_BY=
FM_SECONDMATE_ASLEEP_REASON=

fm_secondmate_asleep_path() {  # <state-dir> <id>
  case "$2" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/%s.asleep\n' "$1" "$2"
}

# True when <id> is asleep in this home. Publishes FM_SECONDMATE_ASLEEP_SINCE,
# FM_SECONDMATE_ASLEEP_BY, and FM_SECONDMATE_ASLEEP_REASON for the report.
fm_secondmate_asleep() {  # <state-dir> <id>
  local marker line
  FM_SECONDMATE_ASLEEP_SINCE=
  FM_SECONDMATE_ASLEEP_BY=
  FM_SECONDMATE_ASLEEP_REASON=
  marker=$(fm_secondmate_asleep_path "$1" "$2") || return 1
  [ -e "$marker" ] || [ -L "$marker" ] || return 1
  if [ -f "$marker" ] && [ ! -L "$marker" ] && [ -r "$marker" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        since=*) FM_SECONDMATE_ASLEEP_SINCE=${line#since=} ;;
        by=*) FM_SECONDMATE_ASLEEP_BY=${line#by=} ;;
        reason=*) FM_SECONDMATE_ASLEEP_REASON=${line#reason=} ;;
      esac
    done < "$marker"
  fi
  [ -n "$FM_SECONDMATE_ASLEEP_SINCE" ] || FM_SECONDMATE_ASLEEP_SINCE=unknown
  [ -n "$FM_SECONDMATE_ASLEEP_BY" ] || FM_SECONDMATE_ASLEEP_BY=unknown
  [ -n "$FM_SECONDMATE_ASLEEP_REASON" ] || FM_SECONDMATE_ASLEEP_REASON="unreadable sleep marker $marker"
  return 0
}

# One report line for the mate fm_secondmate_asleep just read.
fm_secondmate_asleep_line() {
  printf 'asleep since %s (by %s): %s\n' \
    "$FM_SECONDMATE_ASLEEP_SINCE" "$FM_SECONDMATE_ASLEEP_BY" "$FM_SECONDMATE_ASLEEP_REASON"
}

# Record <id> asleep now. The marker is written beside its destination and
# renamed into place, so a reader sees the whole record or none of it.
fm_secondmate_asleep_write() {  # <state-dir> <id> <by> <reason>
  local marker tmp
  marker=$(fm_secondmate_asleep_path "$1" "$2") || return 1
  tmp=$(mktemp "$1/.asleep-$2.XXXXXX" 2>/dev/null) || return 1
  if printf 'since=%s\nby=%s\nreason=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$3" "$4" > "$tmp" \
    && mv -f "$tmp" "$marker"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Remove whatever sits at exactly the marker path - a file, a symlink (never its
# target), or a directory - and succeed only once nothing is left there, since
# any leftover still reads as asleep.
fm_secondmate_asleep_clear() {  # <state-dir> <id>
  local marker
  marker=$(fm_secondmate_asleep_path "$1" "$2") || return 1
  if [ -d "$marker" ] && [ ! -L "$marker" ]; then
    rm -rf -- "$marker" 2>/dev/null
  else
    rm -f -- "$marker" 2>/dev/null
  fi
  [ ! -e "$marker" ] && [ ! -L "$marker" ]
}
