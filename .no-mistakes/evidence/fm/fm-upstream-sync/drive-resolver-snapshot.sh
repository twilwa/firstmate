#!/usr/bin/env bash
# Live driver: runs the real bin/fm-dispatch-resolve.sh CLI (argv + env interface)
# in an isolated FM_HOME. Only the third-party typesafe.ai HTTP call (curl) and
# quota-axi are replaced by recording shims; cp and every other tool are real.
# The brief is rewritten *while the resolver is running*: the rules file is a
# FIFO, so the resolver blocks on `cp rules` (which happens after it snapshots
# the brief); a concurrent writer mutates the brief first, then feeds the rules.
# Usage: drive-resolver-snapshot.sh <path-to-bin-dir>
set -u
BIN=$(cd "$1" && pwd); TOOL="$BIN/fm-dispatch-resolve.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H="$T/home"; FB="$T/fakebin"; LOG="$T/log"; mkdir -p "$H/config" "$H/state" "$FB" "$LOG"
RULES_SRC="$T/rules.json"
cat > "$RULES_SRC" <<'JSON'
{"rules":[{"when":"A simple bug fix with a stated root cause.","use":{"harness":"claude","model":"sonnet","effort":"high"}}],
 "default":[{"harness":"claude","model":"opus"}]}
JSON
cat > "$T/quota.json" <<'JSON'
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":5,"providers":[
 {"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":79,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.5}}]}}]}
JSON
cat > "$T/response.json" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.9,
 "probabilities":{"rule_1":0.96,"default":0.04}}},"usage":{"input_tokens":1,"output_tokens":1}}
JSON
cat > "$FB/curl" <<'C'
#!/usr/bin/env bash
out='' hd=''
while [ $# -gt 0 ]; do case "$1" in -D) hd=$2; shift 2;; -o) out=$2; shift 2;; *) shift;; esac; done
cat > "$LOG/body"; cp "$RESP" "$out"
printf 'HTTP/1.1 200 OK\r\nx-typesafe-request-id: req-live-1\r\n\r\n' > "$hd"; printf 200
C
cat > "$FB/quota-axi" <<'C'
#!/usr/bin/env bash
cat "$QFIX"
C
chmod +x "$FB/curl" "$FB/quota-axi"
export LOG RESP="$T/response.json" QFIX="$T/quota.json"
sha() { sha256sum "$1" | awk '{print $1}'; }
MUTATED=$'# Task\n## Captain\'s intent\nMUTATED WHILE RESOLVING.\n## Firstmate spec\nMUTATED SPEC.\n'

resolve_with_midrun_mutation() { # <brief>
  local brief=$1 rules="$H/config/crew-dispatch.json"
  rm -f "$rules"; mkfifo "$rules"
  ( sleep 0.3; printf '%s' "$MUTATED" > "$brief"; cat "$RULES_SRC" > "$rules" ) &
  PATH="$FB:$PATH" FM_HOME="$H" TYPESAFE_API_KEY=live-test-key "$TOOL" "$brief" --project demo
  echo "exit=$?"
  wait; rm -f "$rules"; cp "$RULES_SRC" "$rules"
}

scenario() { # <label> <brief-content>
  local label=$1 content=$2 brief="$T/$1.md" orig_sha receipt
  printf '%s' "$content" > "$brief"
  cp "$brief" "$T/$label.original"; orig_sha=$(sha "$brief")
  echo "=== $label ==="
  echo "--- original brief (sha256 $orig_sha) ---"; cat "$brief"; echo
  echo "--- resolver stdout (brief rewritten mid-run) ---"
  resolve_with_midrun_mutation "$brief"
  echo "--- brief on disk after run (sha256 $(sha "$brief")) ---"; cat "$brief"
  echo "--- state.task.brief sent to typesafe.ai ---"; jq -r .state.task.brief "$LOG/body"
  receipt=$(jq -sc '[.[]|select(.receipt_type=="resolution")]|last' "$H/state/dispatch-receipts.jsonl")
  echo "--- resolution receipt ---"; jq '{brief_path,brief_sha256,status,chosen_profile,request_id}' <<<"$receipt"
  local rsha; rsha=$(jq -r .brief_sha256 <<<"$receipt")
  [ "$rsha" = "$orig_sha" ] && echo "CHECK receipt.brief_sha256 == sha256(original bytes): PASS" || echo "CHECK receipt.brief_sha256 == sha256(original bytes): FAIL ($rsha)"
  if jq -r .state.task.brief "$LOG/body" | grep -q MUTATED; then echo "CHECK request free of mutated bytes: FAIL"; else echo "CHECK request free of mutated bytes: PASS"; fi
  echo "--- --record-dispatch against the edited brief (must refuse to join) ---"
  PATH="$FB:$PATH" FM_HOME="$H" TYPESAFE_API_KEY=live-test-key "$TOOL" --record-dispatch "$brief" --harness claude --model sonnet; echo "exit=$?"
  cp "$T/$label.original" "$brief"
  echo "--- --record-dispatch after restoring original bytes (must join) ---"
  PATH="$FB:$PATH" FM_HOME="$H" TYPESAFE_API_KEY=live-test-key "$TOOL" --record-dispatch "$brief" --harness claude --model sonnet; echo "exit=$?"
  jq -sc '[.[]|select(.receipt_type=="dispatch")]|last|{receipt_type,brief_sha256,dispatched_profile}' "$H/state/dispatch-receipts.jsonl" 2>/dev/null
  echo
}

scenario section-scout-brief $'# Task\n## Captain\'s intent\nFix the pager off-by-one.\n\n## Firstmate spec\nRoot cause is <= on line 40.\n\n# Definition of done\nThis is a SCOUT task: the deliverable is a written report, not a PR.\n'
scenario whole-brief-fallback $'# Task\nNo recognized subsections here.\nSend this whole brief verbatim.\n'

echo "=== key-absent opt-in gate ==="
cp "$RULES_SRC" "$H/config/crew-dispatch.json"; rm -f "$LOG/body"
env -u TYPESAFE_API_KEY PATH="$FB:$PATH" FM_HOME="$H" "$TOOL" "$T/whole-brief-fallback.md"; echo "exit=$? network_call=$([ -e "$LOG/body" ] && echo yes || echo no)"
