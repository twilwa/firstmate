. /tmp/fm-live-scripts/lib.sh
deliver() { # <home> <id> <content-file>  -> emulate the confined transfer's delivered state
  local h=$1 id=$2 f=$3 gen=${4:-1}
  mkdir -p "$h/state/handoff"; cp "$f" "$h/state/handoff/$id.outbox.md"
  BYTES=$(wc -c < "$f" | tr -d ' '); HASH=$(sha256sum "$f" | awk '{print $1}')
  printf '%s\n%s\n%s\n' "$gen" "$BYTES" "$HASH" > "$h/state/handoff/.$id.upload-generation"
}
receive() { run env FM_HOME="$1" "$ROOT/bin/fm-backlog-receive.sh" "state/handoff/$2.outbox.md" "$BYTES" "$HASH" "${3:-1}"; }
newhome() { R=$(mktemp -d /tmp/fm-lab-rx.XXXXXX); LABS+=("$R"); mkdir -p "$R/bin" "$R/data" "$R/state" "$R/config"; printf '# Firstmate\n' > "$R/AGENTS.md"; printf 'ios\n' > "$R/.fm-secondmate-home"; }
OUT=$(mktemp /tmp/fm-live-outbox.XXXXXX); LABS+=("$OUT")
printf '## Queued\n- [ ] rx-blocker - remote blocker (repo: alpha)\n  remote body line\n- [ ] rx-dependent - remote dependent blocked-by: rx-blocker (repo: alpha)\n\n' > "$OUT"
echo "### S-R1: remote receipt into a Beads(br) home (fork tasks-axi)"
newhome; selector "$R" beads data/.beads br; mirror "$R"
deliver "$R" ios "$OUT"
receive "$R" ios
brlist "$R/data/.beads/beads.db"
say "fm-tasks-axi.sh show rx-dependent --full (receiving home)"; fmaxi "$R" show rx-dependent --full | grep -E 'id:|state|blocked_by|body'
say "receiving mirror"; cat "$R/data/backlog.md"
say "ls state/handoff (scratch released?)"; ls -A "$R/state/handoff"
echo "--- redelivery of the same keys (generation 2): idempotent"
deliver "$R" ios "$OUT" 2; receive "$R" ios 2
brlist "$R/data/.beads/beads.db"; ls -A "$R/state/handoff"

echo; echo "### S-R2: remote receipt into a fresh default markdown home with INSTALLED upstream tasks-axi"
PATH=${PATH#"$SHIM:"}; hash -r; echo "tasks-axi: $(command -v tasks-axi)"
newhome
deliver "$R" ios "$OUT"
receive "$R" ios
say "receiving data/backlog.md"; cat "$R/data/backlog.md"; ls -A "$R/state/handoff"
deliver "$R" ios "$OUT" 2; receive "$R" ios 2
