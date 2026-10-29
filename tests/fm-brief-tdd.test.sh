#!/usr/bin/env bash
# Ship instructions carry the shared testing discipline at the public CLI seam.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-tdd)
mkdir -p "$TMP_ROOT/home/data"

assert_testing_discipline_once() {  # <file> <label>
  local requirement count
  # shellcheck disable=SC2016 # Skill-name backticks are literal generated output.
  for requirement in \
    'Follow the `tdd` skill and the no-mistakes test-quality rule' \
    'red -> green -> refactor in vertical slices' \
    'high-signal tests at public seams' \
    'regression test red before the fix' \
    'no tautological, implementation-coupled, or bulk-ahead tests'; do
    count=$(grep -F -o -- "$requirement" "$1" | wc -l | tr -d ' ')
    [ "$count" = 1 ] || fail "$2 must carry testing requirement exactly once: $requirement"
  done
}

for mode in no-mistakes direct-PR local-only; do
  FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-brief.sh" "tdd-$mode" sample \
    --mode "$mode" --tests focused >/dev/null
  brief="$TMP_ROOT/home/data/tdd-$mode/brief.md"
  assert_testing_discipline_once "$brief" "$mode"
  pass "$mode ship brief carries the shared testing discipline once"
done

mkdir -p "$TMP_ROOT/home/state"
for mode in no-mistakes direct-PR local-only; do
  id="tdd-promote-$mode"
  FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-brief.sh" "$id" sample --scout >/dev/null
  sed -i.bak -e 's/{TASK}/Fix the widget./' -e 's/{FIRSTMATE_SPEC}/Inspect the widget./' \
    "$TMP_ROOT/home/data/$id/brief.md"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$TMP_ROOT/home/state/$id.meta"
  FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-promote.sh" "$id" --mode "$mode" --yolo off >/dev/null 2>&1 \
    || fail "promotion to $mode failed"
  instructions="$TMP_ROOT/home/data/$id/ship-instructions.md"
  assert_testing_discipline_once "$instructions" "promoted $mode"
  pass "promoted $mode ship instructions carry the shared testing discipline once"
done
