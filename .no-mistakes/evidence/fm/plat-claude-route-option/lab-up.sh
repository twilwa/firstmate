#!/usr/bin/env bash
set -eu
SRC={run-worktree}
ROOT=$(mktemp -d /tmp/fmlab.XXXXXX); echo "$ROOT"
LAB="$ROOT/home"
"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git -C "$LAB" init -q -b main
git -C "$LAB" fetch -q "$SRC" HEAD
git -C "$LAB" checkout -q -f -B main FETCH_HEAD
git -C "$LAB" config user.name lab; git -C "$LAB" config user.email lab@example.invalid
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects" "$ROOT/treehouse"
printf 'tmux\n' > "$LAB/config/backend"
printf 'claude\n' > "$LAB/config/crew-harness"
printf 'auto\n' > "$LAB/config/claude-permission-mode"
"$SRC/bin/fm-lab-home.sh" tmux-dir "$LAB" > "$ROOT/tmux_dir"
. ~/.no-mistakes/evidence/01M7V3WE5CC1CWPSPJ6YFFS1F0/lab-env.sh
mkdir -m 700 "$TMUX_DIR/tmux-$(id -u)"
lab_run tmux -S "$SOCK" -f /dev/null new-session -d -s firstmate -n lab -x 220 -y 60 -c "$ROOT"
# project
seed="$ROOT/origins/notes-seed"; origin="$ROOT/origins/notes.git"
mkdir -p "$seed"; git init -q -b main "$seed"; echo "# notes" > "$seed/README.md"
git -C "$seed" add -A; git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
git clone -q --bare "$seed" "$origin"; rm -rf "$seed"
git clone -q "$origin" "$LAB/projects/notes"
printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes library\n' > "$LAB/data/projects.md"
echo "tree: $(git -C "$LAB" rev-parse HEAD)"
