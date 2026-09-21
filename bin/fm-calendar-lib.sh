#!/usr/bin/env bash
# Shared strict UTC-calendar helpers for dated captain-answer writes.

# fm_valid_calendar_day <YYYY-MM-DD>: validate both the wire shape and the
# actual calendar day.
fm_valid_calendar_day() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  perl -MTime::Piece -e '
    my $value = shift;
    my $parsed = eval { Time::Piece->strptime($value, "%Y-%m-%d") };
    exit 1 if !$parsed || $parsed->strftime("%Y-%m-%d") ne $value;
  ' "$1" 2>/dev/null
}

# fm_utc_calendar_day [<UTC observation>]: print one stable UTC calendar day.
# An explicit observation is the deterministic clock shared by send preflight
# and the later keyed-answer mutation.
fm_utc_calendar_day() {
  local observation=${1:-} day
  if [ -z "$observation" ]; then
    date -u +%Y-%m-%d
    return
  fi
  case "$observation" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
      day=${observation%%T*}
      ;;
    *) return 1 ;;
  esac
  fm_valid_calendar_day "$day" || return 1
  printf '%s\n' "$day"
}

# fm_future_calendar_day <YYYY-MM-DD> <UTC-today>: require a useful future
# date under the snapshot owner's strict hold_until > today boundary.
fm_future_calendar_day() {
  fm_valid_calendar_day "$1" || return 1
  fm_valid_calendar_day "$2" || return 1
  [[ "$1" > "$2" ]]
}
