#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_PR_OPT_* are public results consumed by sourcing callers.
# The helper-option prefix of bin/fm-pr-merge.sh, parsed once for both that
# guard and the bin/fm-pr-review.sh merge wrapper, so the waivers the wrapper
# records are exactly the waivers the guard applies.
#
# The prefix ends at a standalone -- (consumed) or at the first argument that
# is not a helper option (kept); everything after it is forge extras passed
# through verbatim. Every option value is its own argument. An --allow-red or
# --expected-head value that is empty or begins with -- is refused rather than
# consumed, so a missing value never borrows the next option or the separator;
# --allow-missing keeps its legacy parse and refuses only an empty value. A
# waiver name beginning with a single - is accepted, and callers hand names to
# jq only after --args --, so a name is always data.
#
# fm_pr_merge_options_parse <args...> sets:
#   FM_PR_OPT_ATTENDED_OVERRIDE   true|false
#   FM_PR_OPT_UPDATE_BRANCH       true|false
#   FM_PR_OPT_ALLOW_NO_PIPELINE   true|false
#   FM_PR_OPT_ALLOW_RED           array of distinct check names, in order, at most 4
#   FM_PR_OPT_ALLOW_MISSING       array of at most one check name
#   FM_PR_OPT_EXPECTED_HEAD       the supplied value, or empty
#   FM_PR_OPT_CONSUMED            how many leading arguments the prefix used
# and returns 2 with an error line on stderr for a malformed prefix.
#
# fm_pr_allow_red_add <option> <name> appends one waiver under the same limits;
# fm-pr-review.sh merge-decision uses it for --allowed-red-check.
#
# Sourced by those scripts and by tests. No side effects on source.

FM_PR_ALLOW_RED_MAX=4

fm_pr_allow_red_add() {  # <option> <name>
  local option=$1 name=${2-} check
  case "$name" in
    ''|--*) echo "error: $option requires a check name" >&2; return 2 ;;
  esac
  for check in ${FM_PR_OPT_ALLOW_RED[@]+"${FM_PR_OPT_ALLOW_RED[@]}"}; do
    [ "$check" != "$name" ] || { echo "error: $option names check '$name' more than once" >&2; return 2; }
  done
  [ "${#FM_PR_OPT_ALLOW_RED[@]}" -lt "$FM_PR_ALLOW_RED_MAX" ] \
    || { echo "error: $option may name at most $FM_PR_ALLOW_RED_MAX checks" >&2; return 2; }
  FM_PR_OPT_ALLOW_RED+=("$name")
}

fm_pr_merge_options_parse() {
  FM_PR_OPT_ATTENDED_OVERRIDE=false
  FM_PR_OPT_UPDATE_BRANCH=false
  FM_PR_OPT_ALLOW_NO_PIPELINE=false
  FM_PR_OPT_ALLOW_RED=()
  FM_PR_OPT_ALLOW_MISSING=()
  FM_PR_OPT_EXPECTED_HEAD=
  FM_PR_OPT_CONSUMED=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --attended-override) FM_PR_OPT_ATTENDED_OVERRIDE=true; shift; FM_PR_OPT_CONSUMED=$((FM_PR_OPT_CONSUMED + 1)) ;;
      --update-branch) FM_PR_OPT_UPDATE_BRANCH=true; shift; FM_PR_OPT_CONSUMED=$((FM_PR_OPT_CONSUMED + 1)) ;;
      --allow-no-pipeline) FM_PR_OPT_ALLOW_NO_PIPELINE=true; shift; FM_PR_OPT_CONSUMED=$((FM_PR_OPT_CONSUMED + 1)) ;;
      --update-branch=*|--attended-override=*|--allow-no-pipeline=*)
        echo "error: ${1%%=*} takes no value" >&2
        return 2
        ;;
      --allow-red)
        fm_pr_allow_red_add --allow-red "${2-}" || return 2
        shift 2
        FM_PR_OPT_CONSUMED=$((FM_PR_OPT_CONSUMED + 2))
        ;;
      --allow-missing)
        [ -n "${2:-}" ] || { echo "error: --allow-missing requires a check name" >&2; return 2; }
        [ "${#FM_PR_OPT_ALLOW_MISSING[@]}" -eq 0 ] || { echo "error: --allow-missing may be specified only once" >&2; return 2; }
        FM_PR_OPT_ALLOW_MISSING+=("$2")
        shift 2
        FM_PR_OPT_CONSUMED=$((FM_PR_OPT_CONSUMED + 2))
        ;;
      --allow-red=*|--allow-missing=*)
        echo "error: ${1%%=*} requires a separate check name argument" >&2
        return 2
        ;;
      --expected-head)
        [ -z "$FM_PR_OPT_EXPECTED_HEAD" ] || { echo "error: --expected-head may be specified only once" >&2; return 2; }
        case "${2:-}" in
          ''|--*) echo "error: --expected-head requires a full commit sha" >&2; return 2 ;;
        esac
        FM_PR_OPT_EXPECTED_HEAD=$2
        shift 2
        FM_PR_OPT_CONSUMED=$((FM_PR_OPT_CONSUMED + 2))
        ;;
      --expected-head=*)
        echo "error: --expected-head requires a separate full commit sha argument" >&2
        return 2
        ;;
      --) FM_PR_OPT_CONSUMED=$((FM_PR_OPT_CONSUMED + 1)); return 0 ;;
      *) return 0 ;;
    esac
  done
}
