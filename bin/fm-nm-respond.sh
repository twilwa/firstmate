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
    --findings) ((!findings_given)) || fail 'pass --findings once; axi keeps only the last value'; findings_given=1; findings=$value ;;
  esac
done

if ((skip && !whole_step && (!step_given || review))); then
  # Even with --step omitted, axi responds to the gate currently awaiting approval.
  # Read its gate before deciding whether a skip is a review-step skip.
  status=$("$nm" axi status) || fail 'cannot read axi status; refusing skip'
  rc=0
  missing=$(printf '%s\n' "$status" | awk -v selected="$findings" '
    BEGIN {
      n = split(selected, tokens, ",")
      for (i = 1; i <= n; i++) if (tokens[i] != "") named[tokens[i]] = 1
    }
    /^[^[:space:]]/ { nested = 0 }
    /^gate:[[:space:]]*$/ { gate = 1; nested = 1; next }
    /^gate:[[:space:]]*[^[:space:]]/ { gate = 1; scalar = 1; step = $2; next }
    nested && /^  step: / { step = $2; next }
    rows && /[^[:space:]]/ {
      row_indent = match($0, /[^ ]/) - 1
      if (row_indent <= indent) rows = 0
      else {
        if (row_indent != indent + 2) next
        id = $0
        sub(/,.*/, "", id)
        sub(/^[[:space:]]+/, "", id)
        if (id == "" || id ~ /[[:space:]]/) bad = 1
        else { seen++; if (!(id in named)) missing[++miss] = id }
        next
      }
    }
    (nested || scalar) && /^[[:space:]]*findings\[[0-9]+\]\{id,/ {
      if (header) bad = 1
      header = 1
      rows = 1
      indent = match($0, /[^ ]/) - 1
      count = $0
      sub(/^[[:space:]]*findings\[/, "", count)
      sub(/\].*/, "", count)
      next
    }
    (nested || scalar) && /^[[:space:]]*findings: none[[:space:]]*$/ { if (header) bad = 1; header = 1; count = 0; next }
    END {
      if (!gate || step == "") exit 2
      if (tolower(step) != "review") exit 3
      if (!header || bad || seen != count) exit 2
      for (i = 1; i <= miss; i++) printf "%s%s", (i == 1 ? "" : ","), missing[i]
    }
  ') || rc=$?
  if ((rc != 3 || review)); then
    ((rc == 0)) || fail 'cannot read open review findings from axi status; refusing skip'
    [ -z "$missing" ] || fail "review skip leaves unnamed open findings: $missing (name each with --findings or use --whole-step)"
  fi
fi
exec "$nm" axi respond ${args[@]+"${args[@]}"}
