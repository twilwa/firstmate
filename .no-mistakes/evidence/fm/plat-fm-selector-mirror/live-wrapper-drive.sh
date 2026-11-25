#!/usr/bin/env bash
# Drives the real bin/fm-tasks-axi.sh wrapper against a disposable home whose
# config/tasks.toml selector names Beads mirror fields. A probe tasks-axi on
# PATH prints the TASKS_AXI_* environment the wrapper hands its child.
set -u
W=$1 T=$2
unset TASKS_AXI_FILE TASKS_AXI_BACKEND TASKS_AXI_BEADS_BINARY TASKS_AXI_BEADS_PATH TASKS_AXI_BEADS_PREFIX TASKS_AXI_BEADS_MIRROR TASKS_AXI_BEADS_MIRROR_ARCHIVE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
H="$T/my home"; mkdir -p "$H/data" "$H/config" "$H/state" "$T/probe"
cp "$W/.tasks.toml" "$H/.tasks.toml" 2>/dev/null || true
printf '# Backlog\n' > "$H/data/backlog.md"
cat > "$T/probe/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "  cwd=$PWD argv=$*"
env | grep '^TASKS_AXI_' | sort | sed 's/^/  /'
SH
chmod +x "$T/probe/tasks-axi"
run() { echo "\$ $*"; (cd "$W" && PATH="$T/probe:/usr/bin:/bin" FM_HOME="$H" "$@" "$W/bin/fm-tasks-axi.sh" list); echo "  exit=$?"; echo; }
sel() { printf '%b' "$1" > "$H/config/tasks.toml"; echo "--- selector:"; sed 's/^/    /' "$H/config/tasks.toml"; }

echo "=== S1 relative + absolute mirror fields, with binary/path/prefix"
sel 'backend = "beads"\n[beads]\nbinary = "br"\npath = ".beads"\nprefix = "fm-home"\nmirror = "data/backlog.md"\nmirror_archive = "/srv/archive/done-archive.md"\n'
run env
echo "=== S2 explicit environment wins (nonempty and empty)"
run env TASKS_AXI_BEADS_MIRROR=/env/mirror.md TASKS_AXI_BEADS_MIRROR_ARCHIVE=
echo "=== S3 quoted literal paths with spaces and #"
sel "backend = \"beads\"\n[beads]\nmirror = 'data/back log #1.md'\nmirror_archive = \"data/done \\\\\"q\\\\\".md\"\n"
run env
echo "=== S4 markdown backend: mirror fields ignored"
sel 'backend = "markdown"\n[beads]\nmirror = "data/backlog.md"\nmirror_archive = "data/done-archive.md"\n'
run env
echo "=== S5 invalid mirror value refused (exit 2, nothing run)"
sel 'backend = "beads"\n[beads]\nmirror = 123\n'
run env
sel 'backend = "beads"\n[beads]\nmirror_archive = data/x.md\n'
run env
echo "=== S6 no selector: native config untouched"
rm -f "$H/config/tasks.toml"; echo "--- selector: (absent)"
run env
