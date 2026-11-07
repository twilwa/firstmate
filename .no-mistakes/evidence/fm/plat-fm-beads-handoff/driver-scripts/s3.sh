. /tmp/fm-live-scripts/lib.sh
seed_beads() { local h=$1 id=$2 t=$3; shift 3; (cd "$h" && FM_HOME="$h" "$ROOT/bin/fm-tasks-axi.sh" add "$id" "$t" --repo alpha --body "body for $id" "$@" >/dev/null 2>&1) || echo "seed failed $id"; }
echo "### S-L5 (adversarial): In-flight and Done Beads source items are refused; source store unchanged"
new_pair
selector "$MAIN" beads data/.beads br; selector "$SUB" beads data/.beads br
seed_beads "$MAIN" live-flying "already in flight"; fmaxi "$MAIN" start live-flying >/dev/null
seed_beads "$MAIN" live-finished "already done"; fmaxi "$MAIN" done live-finished >/dev/null
brlist "$MAIN/data/.beads/beads.db"
handoff live-flying
handoff live-finished
brlist "$MAIN/data/.beads/beads.db"
ls "$SUB/data/.beads/beads.db" 2>&1 || true
[ -d "$SUB/data/.beads" ] && br --db "$SUB/data/.beads/beads.db" list --all 2>&1 | head -3

echo; echo "### S-L6b (adversarial): caller env aims the SOURCE at the destination's Beads store (alias) -> refused, nothing reported as moved"
seed_beads "$SUB" live-alias "already in the sub store"
seed_beads "$MAIN" live-alias2 "real main item"
run env TASKS_AXI_BACKEND=beads TASKS_AXI_BEADS_PATH="$SUB/data/.beads" TASKS_AXI_BEADS_BINARY=br FM_HOME="$MAIN" TMUX_TMPDIR="$TD" "$ROOT/bin/fm-backlog-handoff.sh" design live-alias live-alias2
brlist "$MAIN/data/.beads/beads.db"
brlist "$SUB/data/.beads/beads.db"
echo "inbox records: $(find "$MAIN/state/design.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l)"

echo; echo "### S-L4: default markdown -> markdown handoff (no selector) with the INSTALLED upstream tasks-axi 0.2.6"
PATH=${PATH#"$SHIM:"}; hash -r; echo "tasks-axi: $(command -v tasks-axi)"
new_pair
printf '## In flight\n\n## Queued\n- [ ] live-md2md - plain markdown item (repo: alpha)\n  body one\n    deeper indent kept\n\n## Done\n' > "$MAIN/data/backlog.md"
printf '## In flight\n\n## Queued\n- [ ] sub-existing - already here\n\n## Done\n' > "$SUB/data/backlog.md"
handoff live-md2md
say "main backlog"; cat "$MAIN/data/backlog.md"
say "sub backlog"; cat "$SUB/data/backlog.md"
wakes
handoff live-md2md
