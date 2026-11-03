#!/usr/bin/env bash
# Guard review-step skips: any skip at a review gate, named findings or not,
# marks the whole Review step skipped, so it needs --whole-step.
# Usage: bin/fm-nm-respond.sh [--whole-step] --action ACTION [axi respond flags]
# --whole-step explicitly authorizes a whole review-step skip; it is removed
# before forwarding. --yes, --yes=*, -y, and a repeated --findings are refused;
# every other argument is forwarded unchanged and in order.
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
findings_given=0
while (($#)); do
  arg=$1
  shift
  case $arg in
    --yes|--yes=*|-y) fail '--yes and -y are forbidden for every action' ;;
    --whole-step) whole_step=1; continue ;;
    --action|--step|--findings)
      (($#)) || fail "missing value for $arg"
      name=$arg
      value=$1
      shift
      args+=("$arg" "$value")
      ;;
    --action=*|--step=*|--findings=*)
      name=${arg%%=*}
      value=${arg#*=}
      args+=("$arg")
      ;;
    *) args+=("$arg"); continue ;;
  esac
  lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  case $name in
    --action) if [ "$lower" = skip ]; then skip=1; fi ;;
    --step) step_given=1; if [ "$lower" = review ]; then review=1; fi ;;
    --findings) ((!findings_given)) || fail 'pass --findings once; axi keeps only the last value'; findings_given=1 ;;
  esac
done

if ((skip && !whole_step && !step_given)); then
  # Even with --step omitted, axi responds to the gate currently awaiting approval.
  # Read its gate before deciding whether a skip is a review-step skip.
  status=$("$nm" axi status) || fail 'cannot read axi status; refusing skip'
  gate_step=$(printf '%s\n' "$status" | awk '
    /^[^[:space:]]/ { nested = 0 }
    /^gate:[[:space:]]*$/ { nested = 1; next }
    /^gate:[[:space:]]*[^[:space:]]/ { step = $2; next }
    nested && /^  step: / { step = $2; next }
    END { print tolower(step) }
  ')
  [ -n "$gate_step" ] || fail 'cannot read the awaiting gate step from axi status; refusing skip'
  [ "$gate_step" != review ] || review=1
fi
((!skip || whole_step || !review)) \
  || fail 'a review skip marks the whole Review step skipped, so Push refuses: decline alongside fixes with --action fix --ignore, decline every open finding with --action approve, or pass --whole-step to skip the whole step'
exec "$nm" axi respond ${args[@]+"${args[@]}"}
