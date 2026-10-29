#!/usr/bin/env bash
# usage: fm-lanes-report.sh <checkout>
cd "$1" || exit 1
for l in $(bin/fm-test-run.sh --list-lanes | grep -v '^portable-serial$'); do
  n=$(bin/fm-test-run.sh --list --lane "$l" 2>/dev/null | wc -l)
  ms=$(bin/fm-test-run.sh --estimate-ms --lane "$l" 2>/dev/null)
  printf '%-24s scripts=%-3s estimate_ms=%s\n' "$l" "$n" "$ms"
done
