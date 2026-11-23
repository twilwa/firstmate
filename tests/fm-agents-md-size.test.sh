#!/usr/bin/env bash
# Fork-local size ceiling for the root AGENTS.md supervisor contract.
# Codex's default project_doc_max_bytes (32768) silently truncates a larger
# file, so a supervisor on such a harness never reads the tail of its contract.
# The supervisor harness inventory lives in docs/configuration.md
# "Verification and primary supervision".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Ratchet: when AGENTS.md shrinks, lower this to its new size in the same
# change. Raise it only when growth is unavoidable, with the reason in that
# change's commit message.
AGENTS_MD_MAX_BYTES=55105

TMP_ROOT=$(fm_test_tmproot fm-agents-md-size)

# check_agents_md_size <file> <ceiling>: print a failure explanation and
# return 1 when <file> is larger than <ceiling> bytes.
check_agents_md_size() {
  local file=$1 ceiling=$2 size
  size=$(wc -c < "$file" | tr -d ' ')
  [ "$size" -le "$ceiling" ] && return 0
  printf '%s is %s bytes, over its recorded ceiling of %s bytes.\n' "$file" "$size" "$ceiling"
  printf 'The file must not grow: shrink it, or, if growth is unavoidable, raise AGENTS_MD_MAX_BYTES in tests/fm-agents-md-size.test.sh in the same change with a reason.\n'
  printf "Codex's default project_doc_max_bytes (32768) already truncates this file; every added byte lengthens the part a Codex supervisor never reads.\n"
  return 1
}

test_agents_md_within_ceiling() {
  local out
  out=$(check_agents_md_size "$ROOT/AGENTS.md" "$AGENTS_MD_MAX_BYTES") || fail "$out"
  pass "AGENTS.md is within its ${AGENTS_MD_MAX_BYTES}-byte ceiling"
}

test_oversized_file_is_refused_with_guidance() {
  local fixture=$TMP_ROOT/AGENTS.md out
  head -c "$((AGENTS_MD_MAX_BYTES + 1))" /dev/zero > "$fixture"
  if out=$(check_agents_md_size "$fixture" "$AGENTS_MD_MAX_BYTES"); then
    fail "a file one byte over the ceiling was accepted"
  fi
  assert_contains "$out" "must not grow" "refusal did not forbid growth"
  assert_contains "$out" "raise AGENTS_MD_MAX_BYTES" "refusal did not name the ceiling to raise"
  assert_contains "$out" "project_doc_max_bytes (32768)" "refusal did not name the Codex truncation limit"
  pass "a file one byte over the ceiling is refused with growth guidance"
}

fm_test_run \
  test_agents_md_within_ceiling \
  test_oversized_file_is_refused_with_guidance
