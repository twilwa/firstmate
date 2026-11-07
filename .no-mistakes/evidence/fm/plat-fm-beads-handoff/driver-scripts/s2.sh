. /tmp/fm-live-scripts/lib.sh
seed_beads() { # <home> <id> <title> [--start]
  local h=$1 id=$2 t=$3; shift 3
  (cd "$h" && FM_HOME="$h" "$ROOT/bin/fm-tasks-axi.sh" add "$id" "$t" --repo alpha --body "body for $id" "$@" >/dev/null 2>&1) || echo "seed failed $id"
}
echo "### S-L2: Beads(br) main -> markdown sub"
new_pair
selector "$MAIN" beads data/.beads br; mirror "$MAIN"
selector "$SUB" markdown
printf '## In flight\n\n## Queued\n\n## Done\n' > "$SUB/data/backlog.md"
seed_beads "$MAIN" live-br2md "beads to markdown item"
seed_beads "$MAIN" live-stays "stays behind in main"
brlist "$MAIN/data/.beads/beads.db"
handoff live-br2md
say "cat sub data/backlog.md"; cat "$SUB/data/backlog.md"
brlist "$MAIN/data/.beads/beads.db"
say "fm-tasks-axi.sh list (main)"; fmaxi "$MAIN" list
say "main mirror"; cat "$MAIN/data/backlog.md"
wakes
handoff live-br2md

echo; echo "### S-L5 (adversarial): In-flight Beads source item is refused, source unchanged"
seed_beads "$MAIN" live-flying "already in flight" --start
fmaxi "$MAIN" show live-flying | grep -E 'state'
handoff live-flying
fmaxi "$MAIN" show live-flying | grep -E 'state'
grep -c live-flying "$SUB/data/backlog.md" || true

echo; echo "### S-L3: Beads(br) main -> Beads(br) sub"
new_pair
selector "$MAIN" beads data/.beads br; mirror "$MAIN"
selector "$SUB" beads data/.beads br; mirror "$SUB"
seed_beads "$MAIN" live-blocker "blocker item"
seed_beads "$MAIN" live-dependent "dependent item" --blocked-by live-blocker
handoff live-blocker live-dependent
brlist "$SUB/data/.beads/beads.db"
brlist "$MAIN/data/.beads/beads.db"
say "fm-tasks-axi.sh show live-dependent (sub)"; fmaxi "$SUB" show live-dependent --full | grep -E 'id:|state|blocked_by|body'
say "sub mirror"; cat "$SUB/data/backlog.md"
wakes
handoff live-blocker live-dependent

echo; echo "### S-L6 (adversarial): caller env TASKS_AXI_BACKEND/BEADS_PATH pointing at main store must not collapse homes"
seed_beads "$MAIN" live-envtrap "env override trap"
run env TASKS_AXI_BACKEND=beads TASKS_AXI_BEADS_PATH="$MAIN/data/.beads" TASKS_AXI_BEADS_BINARY=br FM_HOME="$MAIN" TMUX_TMPDIR="$TD" "$ROOT/bin/fm-backlog-handoff.sh" design live-envtrap
brlist "$SUB/data/.beads/beads.db"
brlist "$MAIN/data/.beads/beads.db"

echo; echo "### S-L7 (adversarial): Beads->Beads with differing binary config (main br, sub unset) is refused before moving"
new_pair
selector "$MAIN" beads data/.beads br
selector "$SUB" beads data/.beads
seed_beads "$MAIN" live-binmix "binary mismatch item"
handoff live-binmix
brlist "$MAIN/data/.beads/beads.db"
ls "$SUB/data/.beads"/beads.db 2>&1
