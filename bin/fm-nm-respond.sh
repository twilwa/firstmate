#!/usr/bin/env bash
# Guard review-step skips against leaving unnamed findings open.
# Usage: bin/fm-nm-respond.sh [--whole-step] --action ACTION [axi respond flags]
# --whole-step explicitly authorizes a whole review-step skip; it is removed
# before forwarding. Every other argument is forwarded unchanged and in order.
set -euo pipefail

fail() { printf 'fm-nm-respond: %s\n' "$*" >&2; exit 1; }

# Resolve before any forwarding; never install this wrapper on PATH as no-mistakes.
nm=$(type -P no-mistakes) || fail 'no-mistakes executable not found'
[ -n "$nm" ] || fail 'no-mistakes executable not found'

args=()
whole_step=0
skip=0
review=0
step_given=0
findings=''
while (($#)); do
  arg=$1
  shift
  case $arg in
    --yes|--yes=*|-y) fail '--yes and -y are forbidden for every action' ;;
    --whole-step) whole_step=1 ;;
    --action|--step|--findings)
      (($#)) || fail "missing value for $arg"
      value=$1
      shift
      args+=("$arg" "$value")
      case $arg in
        --action) if [[ ${value,,} == skip ]]; then skip=1; fi ;;
        --step) step_given=1; if [[ ${value,,} == review ]]; then review=1; fi ;;
        --findings) findings+=",$value" ;;
      esac
      ;;
    --action=*|--step=*|--findings=*)
      args+=("$arg")
      value=${arg#*=}
      case ${arg%%=*} in
        --action) if [[ ${value,,} == skip ]]; then skip=1; fi ;;
        --step) step_given=1; if [[ ${value,,} == review ]]; then review=1; fi ;;
        --findings) findings+=",$value" ;;
      esac
      ;;
    *) args+=("$arg") ;;
  esac
done

if ((skip && !whole_step && (!step_given || review))); then
  # Even with --step omitted, axi responds to the gate currently awaiting approval.
  # Read its gate before deciding whether a skip is a review-step skip.
  status=$("$nm" axi status) || fail 'cannot read axi status; refusing skip'
  if ((review)) || { (( !step_given )) && printf '%s\n' "$status" | grep -Eiq '^  step: review[[:space:]]*$|^gate: review[[:space:]]*$'; }; then
    missing=$(printf '%s\n' "$status" | awk -v selected="$findings" '
      BEGIN {
        n = split(selected, tokens, ",")
        for (i = 1; i <= n; i++) if (tokens[i] != "") named[tokens[i]] = 1
      }
      /^gate:([[:space:]]*review[[:space:]]*)?$/ { gate = 1; if ($0 ~ /review/) step = "review"; next }
      gate && /^  step: / { step = $2; next }
      gate && /^[[:space:]]*findings\[[0-9]+\]\{id,/ {
        header = 1
        indent = match($0, /[^ ]/) - 1
        count = $0
        sub(/^[[:space:]]*findings\[/, "", count)
        sub(/\].*/, "", count)
        next
      }
      gate && /^[[:space:]]*findings: none[[:space:]]*$/ { header = 1; count = 0; next }
      gate && header && /^[[:space:]]+/ {
        row_indent = match($0, /[^ ]/) - 1
        if (row_indent != indent + 2) next
        id = $0
        sub(/,.*/, "", id)
        sub(/^[[:space:]]+/, "", id)
        if (id == "" || id ~ /[[:space:]]/) bad = 1
        else { seen++; if (!(id in named)) missing[++miss] = id }
        next
      }
      END {
        if (!gate || step != "review" || !header || bad || seen != count) exit 2
        for (i = 1; i <= miss; i++) printf "%s%s", (i == 1 ? "" : ","), missing[i]
      }
    ') || fail 'cannot read open review findings from axi status; refusing skip'
    [ -z "$missing" ] || fail "review skip leaves unnamed open findings: $missing (name each with --findings or use --whole-step)"
  fi
fi
exec "$nm" axi respond "${args[@]}"
