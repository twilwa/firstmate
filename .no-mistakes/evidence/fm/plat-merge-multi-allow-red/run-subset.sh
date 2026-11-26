#!/usr/bin/env bash
# Run a named subset of test_* functions from a firstmate test file by sourcing
# it with its top-level test invocations removed. Args: worktree testfile test...
set -u
WT=$1; FILE=$2; shift 2
TMPF=$(mktemp "${TMPDIR:-/tmp}/fm-subset.XXXXXX.sh")
sed -e "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$WT/tests/lib.sh\"#" \
    -e '/^test_[a-z0-9_]*$/d' "$WT/$FILE" > "$TMPF"
# shellcheck disable=SC1090
. "$TMPF"
rm -f "$TMPF"
for t in "$@"; do
  echo "=== $t"
  "$t"
done
echo "=== SUBSET DONE"
