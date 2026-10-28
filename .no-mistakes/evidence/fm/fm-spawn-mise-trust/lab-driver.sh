#!/usr/bin/env bash
# Disposable live driver: real fm-spawn.sh into a lab home on a private tmux server.
# Usage: lab.sh up <label> <ref> [--shell <path>] [--config root|dotconfig] [--allowlist] [--inherit <trust>] [--harness <h>]
#        lab.sh down <root>
set -u
SRC=/home/firstmate/.no-mistakes/worktrees/8be14fbb8fb5/01M60MAP5PBP07238PJSY8D9RP
FISHDIR=/tmp/fmmise-fish-dl
OUTBASE=/tmp/fmmise-out
mkdir -p "$OUTBASE"

env_base() { # root shell inherit
  local root=$1 shell=$2 inherit=$3
  printf '%s\n' "HOME=$HOME" "USER=$(id -un)" "LOGNAME=$(id -un)" \
    "PATH=$FISHDIR/bin:$PATH" "SHELL=$shell" "TERM=xterm-256color" "LANG=${LANG:-C.UTF-8}" \
    "TMUX_TMPDIR=$TMUX_DIR" "TREEHOUSE_ROOT=$root/treehouse" "FM_BACKEND=tmux" "DISABLE_AUTOUPDATER=1" \
    "MISE_STATE_DIR=$root/mise/state" \
    "MISE_CONFIG_DIR=$HOME/.config/mise" "MISE_DATA_DIR=$HOME/.local/share/mise" \
    "XDG_CONFIG_HOME=$root/xdg/config" "XDG_DATA_HOME=$root/xdg/data" "XDG_CACHE_HOME=$root/xdg/cache"
  [ "$inherit" = __none__ ] || printf '%s\n' "MISE_TRUSTED_CONFIG_PATHS=$inherit"
}

up() {
  local label=$1 ref=$2; shift 2
  local shell=/bin/bash config=root allowlist=no inherit=__none__ harness=''
  while [ $# -gt 0 ]; do
    case $1 in
      --shell) shell=$2; shift 2 ;;
      --config) config=$2; shift 2 ;;
      --allowlist) allowlist=yes; shift ;;
      --inherit) inherit=$2; shift 2 ;;
      --harness) harness=$2; shift 2 ;;
      *) echo "bad arg $1"; return 2 ;;
    esac
  done
  ROOT=$(mktemp -d /tmp/fmmise.XXXXXX); LAB=$ROOT/home
  local id="mise$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  local out="$OUTBASE/$label.out"
  rm -f "$out"
  echo "root=$ROOT id=$id label=$label ref=$ref shell=$shell config=$config allowlist=$allowlist inherit=$inherit"
  printf 'id=%s\nlabel=%s\n' "$id" "$label" > "$ROOT/.rec"
  "$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null || return 1
  git -C "$LAB" init -q -b main && git -C "$LAB" fetch -q "$SRC" "$ref" && git -C "$LAB" checkout -q -f -B main FETCH_HEAD || return 1
  git -C "$LAB" config user.name lab; git -C "$LAB" config user.email lab@example.invalid
  mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects" "$ROOT/treehouse" "$ROOT/mise/config" "$ROOT/xdg/config" "$ROOT/sibling"
  printf 'tmux\n' > "$LAB/config/backend"
  printf 'claude\n' > "$LAB/config/crew-harness"
  if [ "$allowlist" = yes ]; then printf 'PATH\nHOME\nTERM\nMISE_STATE_DIR\n' > "$LAB/config/launch-env-allowlist"; fi
  # Sibling outside the worktree with its own untrusted config: must stay untrusted.
  printf '[env]\nFM_MISE_PROBE = "sibling"\n' > "$ROOT/sibling/mise.toml"
  # Project: an untrusted mise config plus a task prep script that invokes mise.
  local seed=$ROOT/seed
  mkdir -p "$seed/scripts"
  if [ "$config" = root ]; then
    printf '[env]\nFM_MISE_PROBE = "root-mise-toml-loaded"\n' > "$seed/mise.toml"
  else
    mkdir -p "$seed/.config"
    printf '[env]\nFM_MISE_PROBE = "dot-config-mise-toml-loaded"\n' > "$seed/.config/mise.toml"
  fi
  cat > "$seed/scripts/prep.sh" <<'SH'
#!/bin/sh
# Task prep: load the project's mise environment (stdin is the pane tty).
out=$1 sibling=$2
TTY_ERR=$(tty)
{
  echo "pwd=$(pwd)"
  echo "MISE_TRUSTED_CONFIG_PATHS=${MISE_TRUSTED_CONFIG_PATHS-<unset>}"
  echo "--- mise env (worktree, stdin and stderr on the pane tty):"
  mise env -s bash 2>"$TTY_ERR"; echo "mise-env-rc=$?"
  echo "--- mise env (sibling outside worktree, stdin /dev/null):"
  (cd "$sibling" && mise env -s bash </dev/null); echo "sibling-rc=$?"
} > "$out" 2>&1
echo "PREP DONE; agent starting"
SH
  echo "# bb" > "$seed/README.md"
  git -C "$seed" init -q -b main && git -C "$seed" add -A && git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
  git clone -q --bare "$seed" "$ROOT/origin.git" && rm -rf "$seed"
  git clone -q "$ROOT/origin.git" "$LAB/projects/bb"
  printf '# Projects\n\n- bb [local-only +yolo] - lab mise project\n' > "$LAB/data/projects.md"
  TMUX_DIR=$("$LAB/bin/fm-lab-home.sh" tmux-dir "$LAB") || return 1
  echo "tmux_dir=$TMUX_DIR" >> "$ROOT/.rec"
  local -a base=(); local line
  while IFS= read -r line; do base+=("$line"); done < <(env_base "$ROOT" "$shell" "$inherit")
  env -i "${base[@]}" tmux -f /dev/null new-session -d -s firstmate -n lab -x 220 -y 60 -c "$ROOT" || return 1
  (cd "$LAB" && env -i "${base[@]}" FM_HOME="$LAB" "$LAB/bin/fm-brief.sh" "$id" bb --mode local-only) >/dev/null || return 1
  python3 -I - "$LAB/data/$id/brief.md" <<'PY' || return 1
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", "Lab mise-trust probe worker; run the prep and stop.", 1).replace("{FIRSTMATE_SPEC}", "Nothing else is in scope; end your turn.", 1)
open(p, "w", encoding="utf-8").write(t)
PY
  (cd "$LAB" && env -i "${base[@]}" FM_HOME="$LAB" "$LAB/bin/fm-tasks-axi.sh" add "$id" "lab mise probe" --kind ship --repo bb) >/dev/null || return 1
  [ -n "$harness" ] || harness="sh scripts/prep.sh $out $ROOT/sibling && sleep 3600"
  (cd "$LAB" && env -i "${base[@]}" FM_HOME="$LAB" timeout 240 "$LAB/bin/fm-spawn.sh" "$id" "$LAB/projects/bb" \
    --mode local-only --yolo on --harness "$harness") > "$OUTBASE/$label.spawn.log" 2>&1
  echo "spawn-rc=$?"
  echo "$ROOT"
}

down() {
  local root=$1 id tmuxdir
  [ -f "$root/.rec" ] || { echo "no rec"; return 1; }
  id=$(sed -n 's/^id=//p' "$root/.rec"); tmuxdir=$(sed -n 's/^tmux_dir=//p' "$root/.rec")
  [ -z "$tmuxdir" ] || env -u TMUX TMUX_TMPDIR="$tmuxdir" tmux kill-server 2>/dev/null
  "$root/home/bin/fm-lab-home.sh" teardown "$root/home" 2>/dev/null
  local common hash
  common=$(cd "$root/home/projects/bb/.git" 2>/dev/null && pwd -P)
  if [ -n "$common" ]; then
    hash=$(printf '%s' "$common" | sha256sum | awk '{print substr($1,1,12)}')
    if [ -n "$hash" ] && [ -d "$HOME/.treehouse-fm/$hash/.treehouse" ] && ls "$HOME/.treehouse-fm/$hash/.treehouse" | grep -q '^bb-'; then
      rm -rf "$HOME/.treehouse-fm/$hash"; echo "removed pool $hash"
    fi
  fi
  chmod -R u+w "$root" 2>/dev/null; rm -rf /tmp/fm-"$id" /tmp/fm-"$id"+* "$root"
  echo "down $root ($id)"
}

case $1 in up) shift; up "$@" ;; down) shift; down "$@" ;; esac
