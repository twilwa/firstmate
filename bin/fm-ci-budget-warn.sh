#!/usr/bin/env bash
# fm-ci-budget-warn.sh - emit a warning when a CI test lane or lint partition's
# measured command time crosses its tier's healthy budget. Never fails the job.
#
# The timing-aggregate CI job runs this after combining per-lane timing JSON
# and any lint telemetry sidecars. duration_ms and lint wall_seconds are the
# test or lint command's own elapsed time, not the GitHub Actions job wall.
# A value at or above its budget prints a GitHub warning annotation (and a
# plain warning line for local tests). Shorter lanes stay silent. Missing
# inputs print a warning and still exit 0.
#
# Budgets (one per CI timeout tier in docs/fm-test-portable-shards.md):
#   - Test lanes (portable tier, 3000 s job cap): 2120 s. The tier rule
#     (60 s setup + packing ceiling + 1500 s per-file bound inside the cap)
#     admits ceilings up to 1440 s, but contended green fork-main runs already
#     measure up to 1785 s on a serial shard the current hints model at
#     1180 s, a factor of about 1.513. The budget applies that measured factor
#     to the larger packing ceiling (pool, 1400 s): 1400 s x 1.513 = 2119 s,
#     rounded up to 2120 s, above every measured green lane and 820 s short
#     of the 2940 s where the job cap kills the command.
#   - Lint partitions (normal tier, 1800 s job cap): 1200 s, below the cap
#     and above the slowest measured green partition (1021 s).
#
# Usage:
#   fm-ci-budget-warn.sh <aggregate.json> [lint-telemetry-dir]
#   fm-ci-budget-warn.sh --help
#
# Exit status: 0 always except usage errors (2).
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-ci-budget-warn: %s\n' "$*" >&2
  exit 2
}

LANE_BUDGET_MS=2120000
LINT_BUDGET_MS=1200000
AGGREGATE=
LINT_DIR=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown argument: $1"
      ;;
    *)
      if [ -z "$AGGREGATE" ]; then
        AGGREGATE=$1
      elif [ -z "$LINT_DIR" ]; then
        LINT_DIR=$1
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$AGGREGATE" ] || die "need an aggregate timing JSON (see --help)"

warn() {
  local message=$1
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::warning title=CI budget::%s\n' "$message"
  fi
  printf 'fm-ci-budget-warn: warning: %s\n' "$message" >&2
}

minutes() {  # <ms>
  awk -v ms="$1" 'BEGIN { printf "%.1f", ms / 60000 }'
}

if [ ! -f "$AGGREGATE" ]; then
  warn "no aggregate timing JSON at $AGGREGATE; skipped the lane budget check"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required to read timing JSON"

tmp=$(mktemp "${TMPDIR:-/tmp}/fm-ci-budget-warn.XXXXXX")
trap 'rm -f "$tmp"' EXIT
if ! python3 - "$AGGREGATE" "$LANE_BUDGET_MS" >"$tmp" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
budget = int(sys.argv[2])
try:
    doc = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    print("UNREADABLE\t%s" % exc)
    sys.exit(0)
for lane in doc.get("lanes") or []:
    summary = lane.get("summary") or {}
    try:
        duration = int(summary.get("duration_ms") or 0)
    except (TypeError, ValueError):
        continue
    if duration < budget:
        continue
    selection = lane.get("selection") or lane.get("path") or "unknown lane"
    print("LANE\t%s\t%s" % (selection, duration))
PY
then
  die "failed to parse $AGGREGATE"
fi

while IFS=$'\t' read -r kind selection duration || [ -n "$kind" ]; do
  [ -n "$kind" ] || continue
  case "$kind" in
    UNREADABLE)
      warn "could not parse $AGGREGATE; skipped the lane budget check"
      ;;
    LANE)
      selection=${selection#lane=}
      selection=${selection%%;*}
      warn "lane ${selection} command time was $(minutes "$duration") minutes, above the $(minutes "$LANE_BUDGET_MS")-minute healthy lane budget"
      ;;
  esac
done <"$tmp"

if [ -n "$LINT_DIR" ] && [ -d "$LINT_DIR" ]; then
  while IFS= read -r telemetry; do
    [ -n "$telemetry" ] || continue
    wall=$(awk -F '\t' '$1 == "wall_seconds" { print $2; exit }' "$telemetry")
    partition=$(awk -F '\t' '$1 == "partition" { print $2; exit }' "$telemetry")
    case "$wall" in
      ''|*[!0-9.]*) continue ;;
    esac
    wall_ms=$(awk -v s="$wall" 'BEGIN { printf "%d", s * 1000 }')
    if [ "$wall_ms" -ge "$LINT_BUDGET_MS" ]; then
      warn "lint partition ${partition:-unknown} command time was $(minutes "$wall_ms") minutes, above the $(minutes "$LINT_BUDGET_MS")-minute healthy lint budget"
    fi
  done < <(find "$LINT_DIR" -type f -name '*.tsv' ! -name '*.roots.tsv' | LC_ALL=C sort)
fi

exit 0
