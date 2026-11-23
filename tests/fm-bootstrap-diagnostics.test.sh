#!/usr/bin/env bash
# Every leading TOKEN: diagnostic that bin/fm-bootstrap.sh or
# bin/fm-startup-network.sh prints must be declared in that script's header and
# answered by the bootstrap-diagnostics skill, both in its trigger description
# and in its body, unless it is on the short informational allowlist below.
# The extraction is a regular expression over echo/printf string literals, so a
# token assembled at run time escapes it; that is the accepted cost of not
# parsing bash.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"
SCRIPTS=(bin/fm-bootstrap.sh bin/fm-startup-network.sh)

# token|reason - informational tokens that need no playbook row.
INFORMATIONAL=(
  "BOOTSTRAP_INFO|explicit no-action fact; the skill's description says it means no skill load"
)

informational() {
  local entry
  for entry in "${INFORMATIONAL[@]}"; do
    [ "${entry%%|*}" = "$1" ] && return 0
  done
  return 1
}

emitted_tokens() {
  sed -nE "s/.*(echo|printf)[[:space:]]+(-[a-z]+[[:space:]]+)*[\"']([A-Z][A-Z0-9_]*):.*/\3/p" "$1" | sort -u
}

script_header() {
  awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$1"
}

skill_description() {
  awk '
    NR == 1 && /^---$/ { front = 1; next }
    front && /^---$/ { exit }
    front && /^description:/ { desc = 1; next }
    front && desc && /^[^[:space:]]/ { desc = 0 }
    front && desc { print }
  ' "$SKILL"
}

skill_body() {
  awk 'NR == 1 && /^---$/ { front = 1; next } front && /^---$/ { front = 0; next } !front { print }' "$SKILL"
}

has_word() {
  printf '%s\n' "$2" | grep -Eq "(^|[^A-Z0-9_])$1([^A-Z0-9_]|$)"
}

test_every_emitted_token_has_header_entry_and_playbook_row() {
  local rel script header description body token entry gaps="" seen=" "
  description=$(skill_description)
  body=$(skill_body)
  [ -n "$description" ] || fail "could not read the bootstrap-diagnostics skill description"
  for rel in "${SCRIPTS[@]}"; do
    script="$ROOT/$rel"
    header=$(script_header "$script")
    [ -n "$header" ] || fail "could not read the header of $rel"
    while IFS= read -r token; do
      [ -n "$token" ] || continue
      seen="$seen$token "
      informational "$token" && continue
      has_word "$token" "$header" || gaps="$gaps
  $token: missing from the $rel header"
      has_word "$token" "$description" || gaps="$gaps
  $token: missing from the bootstrap-diagnostics description"
      has_word "$token" "$body" || gaps="$gaps
  $token: missing from the bootstrap-diagnostics body"
    done < <(emitted_tokens "$script")
  done
  [ "$seen" != " " ] || fail "extracted no diagnostic tokens; the extraction pattern no longer matches"
  for entry in "${INFORMATIONAL[@]}"; do
    case "$seen" in
      *" ${entry%%|*} "*) ;;
      *) gaps="$gaps
  ${entry%%|*}: allowlisted as informational but no longer emitted" ;;
    esac
  done
  [ -z "$gaps" ] || fail "diagnostic tokens without a declared owner:$gaps"
  pass "every bootstrap and startup-network diagnostic token has a header entry and a playbook row"
}

fm_test_run test_every_emitted_token_has_header_entry_and_playbook_row
