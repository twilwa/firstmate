. /tmp/fm-live-scripts/lib.sh
newhome() { R=$(mktemp -d /tmp/fm-lab-pv.XXXXXX); LABS+=("$R"); mkdir -p "$R/bin" "$R/data" "$R/config"; printf 'fixture\n' > "$R/AGENTS.md"; printf 'ios\n' > "$R/.fm-secondmate-home"; }
M=$(mktemp /tmp/fm-live-manifest.XXXXXX); LABS+=("$M")
printf 'schema=fm-remote-home-provision.v1\nid_b64=aW9z\ncharter_b64=%s\nproject_count=0\n' "$(printf 'Live provisioning charter.\n' | base64 | tr -d '\n')" > "$M"
provision() { say "FM_HOME=$1 fm-remote-home-provision.sh < manifest"; FM_HOME="$1" "$ROOT/bin/fm-remote-home-provision.sh" < "$M" 2>&1; echo "[exit $?]"; }
echo "### S-P1: provisioning converges an existing Beads(br) home through its configured backend"
newhome; selector "$R" beads data/.beads br; mirror "$R"
(cd "$R" && FM_HOME="$R" "$ROOT/bin/fm-tasks-axi.sh" add pv-existing "pre-existing beads item" --repo alpha >/dev/null 2>&1)
cp "$R/data/backlog.md" "$R/mirror-before"
provision "$R"
brlist "$R/data/.beads/beads.db"
say "mirror unchanged?"; cmp "$R/mirror-before" "$R/data/backlog.md" && echo "mirror bytes unchanged"
say "data/ contents"; ls -A "$R/data"
echo; echo "### S-P2 (adversarial): Beads initialization failure aborts provisioning and leaves the existing database and mirror"
chmod 000 "$R/data/.beads"
provision "$R"
chmod 755 "$R/data/.beads"
brlist "$R/data/.beads/beads.db"
cmp "$R/mirror-before" "$R/data/backlog.md" && echo "mirror bytes unchanged"
echo; echo "### S-P3: provisioning an existing default (markdown) home with no backlog creates the canonical scaffold (installed upstream tasks-axi)"
PATH=${PATH#"$SHIM:"}; hash -r; echo "tasks-axi: $(command -v tasks-axi)"
newhome
provision "$R"
say "data/backlog.md bytes"; od -c "$R/data/backlog.md" | head; printf '## In flight\n\n## Queued\n\n## Done\n' | cmp - "$R/data/backlog.md" && echo "scaffold matches the pre-change bytes"
