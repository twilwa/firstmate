#!/usr/bin/env bash
# Round-2 extractor: redacted structural evidence for one startup run (the full
# digest carries private home content and is removed after extraction).
set -u
i=$1; ROOT=/tmp/fm-nm-test-r2.aM1ROD; W=/home/firstmate/firstmate/data/fm-startup-repair-finish/opus-gate/worktrees/85029a4da11b/01M39BB0DGS93EC4MZHQXTCBA5
E=/home/firstmate/firstmate/data/fm-startup-repair-finish/opus-gate/evidence/01M39BB0DGS93EC4MZHQXTCBA5
H=$ROOT/home-$i; O=$E/r2-startup-run-$i; D=$O/session-start.out
start=$(awk -F'\t' '$2=="start"{print $1}' "$O/stage-times.tsv")
{
  echo "# Redacted structural extract of fm-session-start.sh stdout ($(wc -c <"$D") bytes, $(wc -l <"$D") lines) at $(git -C "$W" rev-parse --short HEAD)"
  echo "## Section headers (line: name)"
  grep -n -x -E '[A-Z][A-Z -]+' "$D" | grep -v -E ':=+$' | head -20
  echo "## LOCK"; sed -n '/^LOCK$/,/^BOOTSTRAP$/p' "$D" | grep -i 'lock acquired'
  echo "## NETWORK CHECKS section"; sed -n '/^NETWORK CHECKS$/,/^CONTEXT$/p' "$D" | sed '$d'
  echo "## projection cleanup diagnostics"; grep -c 'projection cleanup' "$D" | sed 's/^/count=/'; grep -o 'projection cleanup: session [^ ]* [a-z ]*' "$D" | sort | uniq -c
  echo "## '●  STARTUP TRUNCATED' banner lines: $(grep -c '^●  STARTUP TRUNCATED' "$D")"; echo "## all ●-banner lines:"; grep '^●' "$D" || echo '(none)'
  echo "## 'Argument list too long' occurrences (stdout+stderr): $(cat "$D" "$O/session-start.err" | grep -c 'Argument list too long')"
  echo "## stderr bytes: $(wc -c <"$O/session-start.err")"
  echo "## final lines"; tail -3 "$D"
} > "$O/session-start.structure.txt"
env -u HERDR_SESSION FM_HOME="$H" TMPDIR="$H/tmp" PATH="$ROOT/guard:$PATH" FM_TEST_HERDR_COMMAND_LOG=/dev/null \
  "$W/bin/fm-startup-network.sh" report > "$O/network.report"
S=$H/state/home-summary.json
{ jq -c '{schema, keys:(keys|length)}' "$S"; m=$(stat -c %Y "$S"); echo "mtime_epoch=$m start_epoch=${start%.*} refreshed_during_run=$([ "$m" -ge "${start%.*}" ] && echo yes || echo no)"; } > "$O/home-summary.check"
{ echo "leftover .herdr-cleanup-locks.* records: $(ls -A "$H/state" | grep -c '^\.herdr-cleanup-locks\.')"
  echo "herdr verbs (guard log):"; awk '{print $1, $2, $3}' "$O/herdr-commands.log" | sort | uniq -c | sort -rn; } > "$O/herdr-summary.txt"
rm -f "$D"
