#!/usr/bin/env bash
# Public-interface regression tests for guarded no-mistakes gate responses.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# Resolve before PATH changes; the fake below must never invoke this binary.
real_nm=$(type -P no-mistakes)
[ -n "$real_nm" ] || { echo 'no-mistakes missing' >&2; exit 1; }
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
rg -q 'review-2' "$tmp/out"
accept --findings=review-1 --action=skip --findings review-2 --step=review
printf '%s\n' '--findings=review-1' '--action=skip' '--findings' 'review-2' '--step=review' > "$tmp/expected"
diff -u "$tmp/expected" "$FM_NM_ARGS"
accept --action skip --step review --whole-step
printf '%s\n' '--action' 'skip' '--step' 'review' > "$tmp/expected"
diff -u "$tmp/expected" "$FM_NM_ARGS"
accept --action skip --step test
accept --action skip --findings review-1,review-2
refuse --action skip --findings review-1
rg -q 'review-2' "$tmp/out"
FM_NM_STATUS_FAIL=1 refuse --action skip --step review
rg -q 'cannot read axi status' "$tmp/out"
refuse --action approve --yes
refuse --yes=true --action skip --step test
refuse -y --action fix
# An unreadable findings section is not evidence of an empty review gate.
FM_NM_STATUS='gate:
  step: review
  status: awaiting_approval' refuse --action skip --step review
rg -q 'cannot read open review findings' "$tmp/out"
echo 'fm-nm-respond: PASS'
