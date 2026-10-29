#!/usr/bin/env bash
# Ship instructions carry the shared testing discipline at the public CLI seam.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-tdd)
mkdir -p "$TMP_ROOT/home/data"

for mode in no-mistakes direct-PR local-only; do
  FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-brief.sh" "tdd-$mode" sample \
    --mode "$mode" --tests focused >/dev/null
  brief="$TMP_ROOT/home/data/tdd-$mode/brief.md"
  # shellcheck disable=SC2016 # Skill-name backticks are literal brief output.
  for requirement in \
    'Follow the `tdd` skill and the no-mistakes test-quality rule' \
    'red -> green -> refactor in vertical slices' \
    'high-signal tests at public seams' \
    'regression test red before the fix' \
    'no tautological, implementation-coupled, or bulk-ahead tests'; do
    count=$(rg -F -o "$requirement" "$brief" | awk 'END { print NR }')
    [ "$count" = 1 ] || fail "$mode must carry testing requirement exactly once: $requirement"
  done
  pass "$mode ship brief carries the shared testing discipline once"
done
