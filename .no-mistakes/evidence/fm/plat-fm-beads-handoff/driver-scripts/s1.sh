. /tmp/fm-live-scripts/lib.sh
echo "### S-L1: markdown main -> Beads(br) sub, local handoff"
tasks-axi --version; br --version
new_pair
selector "$MAIN" markdown
selector "$SUB" beads data/.beads br
mirror "$SUB"
printf '## In flight\n\n## Queued\n- [ ] live-md2br - markdown to beads item (repo: alpha)\n  body survives the move\n  ## Intent\n  keep this pseudo-heading\n\n## Done\n' > "$MAIN/data/backlog.md"
handoff live-md2br
say "fm-tasks-axi.sh show live-md2br --full  (FM_HOME=sub, selector-resolved)"; fmaxi "$SUB" show live-md2br --full
brlist "$SUB/data/.beads/beads.db"
say "cat main data/backlog.md"; cat "$MAIN/data/backlog.md"
say "cat sub data/backlog.md (adapter-owned mirror)"; cat "$SUB/data/backlog.md"
wakes
echo "### retry (idempotent)"
handoff live-md2br
wakes
