#!/usr/bin/env bash
# Every leading TOKEN: diagnostic that bin/fm-bootstrap.sh or
# bin/fm-startup-network.sh prints must be declared in that script's header and
# answered by the bootstrap-diagnostics skill: named in its trigger description
# and given a playbook row (a body list item opening with `TOKEN) - unless it is
# an informational token below. An informational line that a declared
# actionable pattern matches still needs a row quoting its exact message.
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

# ERE|reason - informational messages that still ask the supervisor to act.
ACTIONABLE_INFORMATIONAL=(
  "may remain and should be reconciled\$|interrupted cleanup left a resource to reconcile"
)

informational() {
  local entry
  for entry in "${INFORMATIONAL[@]}"; do
    [ "${entry%%|*}" = "$1" ] && return 0
  done
  return 1
}

# Prints "TOKEN<TAB>TOKEN: message" for each diagnostic literal, with each shell
# expansion or printf conversion in the message normalized to <x>.
emitted_diagnostics() {
  sed -nE "s/.*(echo|printf)[[:space:]]+(-[a-z]+[[:space:]]+)*([\"'])(([A-Z][A-Z0-9_]*):[^\"']*).*/\5	\4/p" "$1" |
    sed -E 's/\$\{[^}]*\}/<x>/g; s/\$[A-Za-z_][A-Za-z0-9_]*/<x>/g; s/%s/<x>/g; s/\\n$//' | sort -u
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

# The quoted line each playbook row opens with, placeholders normalized to <x>.
# shellcheck disable=SC2016 # literal backticks, not an expansion
skill_rows() {
  awk 'NR == 1 && /^---$/ { front = 1; next } front && /^---$/ { front = 0; next } !front { print }' "$SKILL" |
    sed -nE 's/^- `([^`]*)`.*/\1/p' | sed -E 's/<[^>]*>/<x>/g'
}

has_word() {
  printf '%s\n' "$2" | grep -Eq "(^|[^A-Z0-9_])$1([^A-Z0-9_]|$)"
}

has_row() {
  printf '%s\n' "$2" | grep -Eq "^$1(:|$)"
}

actionable_informational() {
  local entry
  for entry in "${ACTIONABLE_INFORMATIONAL[@]}"; do
    printf '%s\n' "$1" | grep -Eq "${entry%%|*}" && return 0
  done
  return 1
}

test_every_emitted_token_has_header_entry_and_playbook_row() {
  local rel script header description rows token message entry gaps="" seen=" " checked diagnostics
  description=$(skill_description)
  rows=$(skill_rows)
  [ -n "$description" ] || fail "could not read the bootstrap-diagnostics skill description"
  [ -n "$rows" ] || fail "could not read any bootstrap-diagnostics playbook rows"
  for rel in "${SCRIPTS[@]}"; do
    script="$ROOT/$rel"
    header=$(script_header "$script")
    [ -n "$header" ] || fail "could not read the header of $rel"
    checked=" "
    diagnostics=$(emitted_diagnostics "$script")
    [ -n "$diagnostics" ] || gaps="$gaps
  $rel: extracted no diagnostic tokens; the extraction pattern no longer matches"
    while IFS=$'\t' read -r token message; do
      [ -n "$token" ] || continue
      case "$seen" in *" $token "*) ;; *) seen="$seen$token " ;; esac
      if informational "$token"; then
        if actionable_informational "$message" \
          && ! printf '%s\n' "$rows" | grep -Fxq "$message"; then
          gaps="$gaps
  $message: actionable but has no matching bootstrap-diagnostics row"
        fi
        continue
      fi
      case "$checked" in *" $token "*) continue ;; esac
      checked="$checked$token "
      has_word "$token" "$header" || gaps="$gaps
  $token: missing from the $rel header"
      has_word "$token" "$description" || gaps="$gaps
  $token: missing from the bootstrap-diagnostics description"
      has_row "$token" "$rows" || gaps="$gaps
  $token: has no bootstrap-diagnostics playbook row"
    done <<<"$diagnostics"
  done
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
