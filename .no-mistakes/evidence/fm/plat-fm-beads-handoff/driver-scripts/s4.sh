. /tmp/fm-live-scripts/lib.sh
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
