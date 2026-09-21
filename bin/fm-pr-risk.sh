#!/usr/bin/env bash
# Classify one GitHub pull request's changed surface as low or high stakes.
#
# The input is a JSON array in GitHub's pull-files shape. Every entry must have
# filename, status, additions and deletions. This script is the single owner of
# the classification decision. The tracked review-policy file owns only numeric
# thresholds; uncertain or malformed input always resolves to high stakes.
#
# Usage: fm-pr-risk.sh <pull-files.json>
# Output: one JSON object with level and reason.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY="$ROOT/.github/firstmate-review-policy.json"

fail_high() {
  jq -cn --arg reason "$1" '{level:"high",reason:$reason}'
  exit 0
}

[ "$#" -eq 1 ] || { echo 'usage: fm-pr-risk.sh <pull-files.json>' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'fm-pr-risk: jq is required' >&2; exit 2; }
[ -f "$POLICY" ] && [ ! -L "$POLICY" ] || fail_high 'review policy configuration is unavailable, so risk is uncertain'
[ -f "$1" ] && [ ! -L "$1" ] || fail_high 'changed-surface evidence is unavailable, so risk is uncertain'

if ! jq -e '
    type == "array" and length > 0 and
    all(.[];
      (.filename | type == "string" and length > 0) and
      (.status | type == "string" and length > 0) and
      (.additions | type == "number" and . >= 0 and floor == .) and
      (.deletions | type == "number" and . >= 0 and floor == .))
  ' "$1" >/dev/null 2>&1; then
  fail_high 'changed-surface evidence is incomplete, so risk is uncertain'
fi

BROAD_FILES=$(jq -er '.broad_change.files' "$POLICY") || fail_high 'review policy thresholds are unreadable, so risk is uncertain'
BROAD_LINES=$(jq -er '.broad_change.changed_lines' "$POLICY") || fail_high 'review policy thresholds are unreadable, so risk is uncertain'
LOW_FILES=$(jq -er '.low_stakes.files' "$POLICY") || fail_high 'review policy thresholds are unreadable, so risk is uncertain'
LOW_LINES=$(jq -er '.low_stakes.changed_lines' "$POLICY") || fail_high 'review policy thresholds are unreadable, so risk is uncertain'
COUNT=$(jq 'length' "$1")
LINES=$(jq '[.[] | .additions + .deletions] | add' "$1")

if [ "$COUNT" -ge "$BROAD_FILES" ] || [ "$LINES" -ge "$BROAD_LINES" ]; then
  jq -cn --argjson files "$COUNT" --argjson lines "$LINES" \
    '{level:"high",reason:("broad change: " + ($files|tostring) + " files and " + ($lines|tostring) + " changed lines")}'
  exit 0
fi

SENSITIVE=$(jq -r '
  .[].filename
  | select(test(
      "(^|/)(auth(entication|ori[sz]ation)?|permissions?|secrets?|credentials?|migrat(e|ions?)|schema|payments?|billing|money)(/|\\.|$)";
      "i") or
    test("(^|/)(api|openapi|swagger|proto)([./-]|$)"; "i") or
    test("(^|/)(deploy(ment)?s?|production|infra(structure)?|terraform|kubernetes|k8s|helm|charts?|cloudformation|pulumi|ansible)([./-]|$)"; "i") or
    test("(^|/)\\.github/workflows(/|$)"; "i") or
    test("(^|/)(fm-pr-(merge|review|review-snapshot|risk))([./-]|$)"; "i") or
    test("(^|/)firstmate-review-policy[.]json$"; "i") or
    test("(^|/)(fm-(spawn|teardown|control|watch|session|afk|merge|lease|recover)|backends?)([./-]|$)"; "i"))
  ' "$1" | head -1)
if [ -n "$SENSITIVE" ]; then
  jq -cn --arg path "$SENSITIVE" \
    '{level:"high",reason:("high-stakes surface: " + $path + " affects lifecycle, recovery, permissions, secrets, production, schema, or money")}'
  exit 0
fi

if [ "$COUNT" -le "$LOW_FILES" ] && [ "$LINES" -le "$LOW_LINES" ]; then
  ONLY_DOCS_TESTS=$(jq -e 'all(.[].filename; test("(^|/)(docs?|tests?|test|spec|README|CONTRIBUTING)(/|\\.|$)"; "i"))' "$1" >/dev/null 2>&1 && echo true || echo false)
  if [ "$ONLY_DOCS_TESTS" = true ]; then
    jq -cn --argjson files "$COUNT" --argjson lines "$LINES" \
      '{level:"low",reason:("small reversible docs/tests change: " + ($files|tostring) + " files and " + ($lines|tostring) + " changed lines")}'
  else
    jq -cn --argjson files "$COUNT" --argjson lines "$LINES" \
      '{level:"low",reason:("bounded reversible implementation: " + ($files|tostring) + " files and " + ($lines|tostring) + " changed lines, with no high-stakes surface detected")}'
  fi
  exit 0
fi

fail_high "change exceeds the bounded low-stakes envelope ($COUNT files and $LINES changed lines), so risk is uncertain"
