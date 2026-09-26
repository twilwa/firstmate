#!/usr/bin/env bash
# Evidence driver: runs the real bin/fm-nm-respond.sh from a foreign project cwd,
# backed by a recording no-mistakes shim that replays the documented v1.79.0
# review-gate TOON and records (never forwards) axi respond argv.
set -u
WT=$1
WRAP=$2   # absolute path, exactly as rendered in the generated worker brief
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/other-project"
cat > "$tmp/bin/no-mistakes" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  'axi status') printf '%s\n' "$GATE" ;;
  'axi respond') shift 2; printf 'FORWARDED to no-mistakes axi respond:'; printf ' [%s]' "$@"; echo ;;
  *) echo "unexpected shim call: $*" >&2; exit 98 ;;
esac
SHIM
chmod +x "$tmp/bin/no-mistakes"
export PATH="$tmp/bin:$PATH"
HELP='help[6]:
  Run `no-mistakes axi respond --action approve` to accept this step and continue
  Run `no-mistakes axi respond --action fix --findings <ids>` to have the pipeline fix the selected findings (do not edit files yourself)
  Run `no-mistakes axi respond --action skip` to skip this step
  Run `no-mistakes axi logs --step review --full` to read the full step log
  A long-running call is working, not stalled - background it if your harness needs to, but the run never advances past a gate on its own. Read every return; on a `gate:`, respond; loop until an `outcome:`.
  Commit post-pipeline follow-up work on top of the existing branch so every pipeline fix commit remains present. Never abort-and-restart, reset, or replace the branch in a way that drops prior gate-fix commits.'
REVIEW2="gate: review
note: Review auto-fix is disabled by default (auto_fix.review: 0; a repo or global auto_fix.review > 0 override re-enables it), so blocking and ask-user review findings park for your decision rather than being silently self-fixed.
findings[2]{id,severity,file,line,action,description}:
  r1,warning,internal/pipeline/executor.go,,auto-fix,Error from os.Remove is ignored
  r2,error,cmd/no-mistakes/main.go,,ask-user,New --force flag bypasses the confirm prompt
$HELP"
REVIEW0="gate: review
findings: none
$HELP"
TESTGATE="gate: test
findings[1]{id,severity,file,line,action,description}:
  t1,warning,a.sh,,auto-fix,flaky
$HELP"
run() {  # <scenario> <gate> args...
  local name=$1 gate=$2; shift 2
  printf '\n### %s\n$ cd other-project && %s' "$name" "$WRAP"; printf ' %q' "$@"; echo
  (cd "$tmp/other-project" && GATE=$gate "$WRAP" "$@" 2>&1); echo "exit=$?"
}
echo "wrapper: $WRAP   bash: $BASH_VERSION   cwd for calls: a non-Firstmate project dir"
echo "gate fixture (review, 2 open findings):"; printf '%s\n' "$REVIEW2" | sed 's/^/  | /'
run 'S1 incident replay: help-line whole-step skip with r1 decided, r2 undecided' "$REVIEW2" --action skip
run 'S1b skip naming only r1 leaves r2 open' "$REVIEW2" --action skip --findings r1
run 'S1c mixed case / = forms cannot dodge the guard' "$REVIEW2" --action=SKIP --step=Review --findings=r1
run 'S1d repeated --findings (axi keeps last) cannot name both' "$REVIEW2" --action skip --findings r1 --findings r2
run 'S2 one-by-one: skip naming every open finding is forwarded' "$REVIEW2" --action skip --findings r1,r2
run 'S3 explicit --whole-step skip is forwarded, flag stripped' "$REVIEW2" --whole-step --action skip --step review
run 'S4 non-skip actions pass through (fix one finding)' "$REVIEW2" --action fix --findings r1 --instructions '-y keep it small'
run 'S4b approve passes through' "$REVIEW2" --action approve
run 'S5 skip on a non-review gate is not blocked' "$TESTGATE" --action skip
run 'S5b empty review gate skip is allowed' "$REVIEW0" --action skip
run 'S6 unreadable status refuses skip (fail closed)' "gate: review" --action skip
run 'S7 --yes refused' "$REVIEW2" --action approve --yes
run 'S7b -y refused' "$REVIEW2" -y --action fix --findings r1
run 'S7c --yes=true refused' "$REVIEW2" --yes=true --action skip --step test
