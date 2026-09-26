#!/usr/bin/env bash
# Public-interface regression tests for guarded no-mistakes gate responses.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/no-mistakes" <<'STUB'
#!/usr/bin/env bash
# Test-only fake: never exec the real binary.
set -eu
[ "${FM_NM_STUB_ACTIVE:-}" != 1 ] || exit 99
export FM_NM_STUB_ACTIVE=1
case "$1 $2" in
  'axi status')
    [ "${FM_NM_STATUS_FAIL:-0}" != 1 ] || exit 2
    printf '%s\n' "$FM_NM_STATUS"
    ;;
  'axi respond')
    shift 2
    printf '%s\n' "$@" > "$FM_NM_ARGS"
    ;;
  *) exit 98 ;;
esac
STUB
chmod +x "$tmp/bin/no-mistakes"
head -n2 "$tmp/bin/no-mistakes"
export PATH="$tmp/bin:$PATH" FM_NM_ARGS="$tmp/args"
export FM_NM_STATUS='run:
  status: running
  findings: 2 awaiting
gate:
  step: review
  status: awaiting_approval
  findings[2]{id,severity,file,action,description}:
    review-1,error,a.sh,ask-user,"first finding"
    review-2,warning,b.sh,ask-user,"second finding"'

refuse() {
  rm -f "$FM_NM_ARGS"
  if "$root/bin/fm-nm-respond.sh" "$@" > "$tmp/out" 2>&1; then
    echo "unexpected response acceptance: $*" >&2; exit 1
  fi
  [ ! -e "$FM_NM_ARGS" ] || { echo 'refused response reached axi' >&2; exit 1; }
}
accept() {
  rm -f "$FM_NM_ARGS"
  "$root/bin/fm-nm-respond.sh" "$@" > "$tmp/out" 2>&1 || {
    echo "response refused: $*" >&2; exit 1
  }
  [ -e "$FM_NM_ARGS" ] || { echo 'response never reached axi' >&2; exit 1; }
}

refuse --action skip --step review --findings=review-1
grep -q 'review-2' "$tmp/out"
# axi keeps only the last --findings value, so a repeat cannot name both.
refuse --findings=review-1 --action=skip --findings review-2 --step=review
grep -q 'pass --findings once' "$tmp/out"
refuse --findings=review-1,review-2 --action approve --findings review-2
accept --findings=review-1,review-2 --action=skip --step=review
printf '%s\n' '--findings=review-1,review-2' '--action=skip' '--step=review' > "$tmp/expected"
diff -u "$tmp/expected" "$FM_NM_ARGS"
accept --action skip --step review --whole-step
printf '%s\n' '--action' 'skip' '--step' 'review' > "$tmp/expected"
diff -u "$tmp/expected" "$FM_NM_ARGS"
accept --action skip --step test
refuse --action SKIP --step Review --findings review-1
grep -q 'review-2' "$tmp/out"
accept --action=Skip --step=TEST
accept --action skip --findings review-1,review-2
refuse --action skip --findings review-1
grep -q 'review-2' "$tmp/out"
FM_NM_STATUS_FAIL=1 refuse --action skip --step review
grep -q 'cannot read axi status' "$tmp/out"
refuse --action approve --yes
refuse --yes=true --action skip --step test
refuse -y --action fix
refuse --action approve -y
accept --action fix --instructions '-y something'
printf '%s\n' '--action' 'fix' '--instructions' '-y something' > "$tmp/expected"
diff -u "$tmp/expected" "$FM_NM_ARGS"
# An unreadable findings section is not evidence of an empty review gate.
FM_NM_STATUS='gate:
  step: review
  status: awaiting_approval' refuse --action skip --step review
grep -q 'cannot read open review findings' "$tmp/out"
# Installed AXI may render the gate as a scalar with a top-level findings table.
FM_NM_STATUS='gate: review
findings[2]{id,severity,file,line,action,description}:
  r1,warning,a.sh,,auto-fix,first
  r2,error,b.sh,,ask-user,second' refuse --action=skip --step=review --findings=r1
grep -q 'r2' "$tmp/out"
FM_NM_STATUS='gate: review
findings[2]{id,severity,file,line,action,description}:
  r1,warning,a.sh,,auto-fix,first
  r2,error,b.sh,,ask-user,second' accept --action=skip --findings=r1,r2
FM_NM_STATUS='gate: review
findings[2]{id,severity,file,line,action,description}:
  r1,warning,a.sh,,auto-fix,first
  r2,error,b.sh,,ask-user,second' accept --action=skip --whole-step
# Real AXI output follows the findings table with a help list at the same row indent.
# shellcheck disable=SC2016 # Backticks are literal AXI help text.
help='help[2]:
  Run `no-mistakes axi respond --action approve` to accept this step and continue
  Run `no-mistakes axi respond --action skip` to skip this step'
FM_NM_STATUS="gate: review
findings[2]{id,severity,file,line,action,description}:
  r1,warning,a.sh,,auto-fix,first
  r2,error,b.sh,,ask-user,second
$help" accept --action=skip --findings=r1,r2
FM_NM_STATUS="gate: review
findings[2]{id,severity,file,line,action,description}:
  r1,warning,a.sh,,auto-fix,first
  r2,error,b.sh,,ask-user,second
$help" refuse --action=skip --findings=r1
grep -q 'unnamed open findings: r2 ' "$tmp/out"
FM_NM_STATUS="gate: review
findings: none
$help" accept --action skip
FM_NM_STATUS="gate:
  step: review
  findings[1]{id,severity,file,action,description}:
    review-1,error,a.sh,ask-user,first
$help" accept --action skip --findings review-1
# Only the gate section names the awaiting step.
FM_NM_STATUS="gate:
  step: test
  status: awaiting_approval
history:
  step: review
$help" accept --action skip
echo 'fm-nm-respond: PASS'
