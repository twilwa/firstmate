#!/usr/bin/env bash
# Exercise the launch-command composition seam with real fixture files and /bin/sh.
# Probe expressions deliberately expand only in the destination shell.
# shellcheck disable=SC2016
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Production modules are linted separately.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-launch-mise-env-lib.sh"

# A quote and space in the directory must remain data, never shell syntax.
WT="$TMP/worker's copy"
mkdir -p "$WT"
launch=$(fm_launch_mise_env "$WT" 'printf "%s" "$MISE_TRUSTED_CONFIG_PATHS"')
actual=$(env -u MISE_TRUSTED_CONFIG_PATHS /bin/sh -c "$launch")
[[ "$actual" == "$WT" ]] || {
  printf 'FAIL: worktree not trusted in worker environment: %s\n' "$actual" >&2
  exit 1
}
printf 'PASS: launch trusts the worktree directory\n'

actual=$(MISE_TRUSTED_CONFIG_PATHS=/existing /bin/sh -c "$launch")
[[ "$actual" == "/existing:$WT" ]] || exit 1
printf 'PASS: existing destination trust is retained\n'

# The explicit assignment survives env -i without forwarding ambient trust.
actual=$(MISE_TRUSTED_CONFIG_PATHS=/existing /usr/bin/env -i /bin/sh -c "$launch")
[[ "$actual" == "$WT" ]] || exit 1
printf 'PASS: worktree trust survives filtered launch\n'

# mise itself must accept every config beneath the worktree, whatever its name,
# and still refuse a sibling directory that shares the worktree's name prefix.
if ! MISE=$(command -v mise); then
  printf 'SKIP: mise not on PATH; real trust resolution not exercised\n'
  exit 0
fi
mkdir -p "$WT/.config" "$WT/sub" "$WT-sibling" "$TMP/home"
printf '[env]\nFM_PROBE = "root"\n' >"$WT/.config/mise.toml"
printf '[env]\nFM_PROBE_LOCAL = "local"\n' >"$WT/mise.local.toml"
printf '[env]\nFM_PROBE_SUB = "sub"\n' >"$WT/sub/mise.toml"
printf '[env]\nFM_PROBE = "sibling"\n' >"$WT-sibling/mise.toml"
mise_probe() { # <dir>
  local dir=$1 launch
  launch=$(fm_launch_mise_env "$WT" "cd '${dir//\'/\'\\\'\'}' && '$MISE' env")
  /usr/bin/env -i PATH="$PATH" HOME="$TMP/home" MISE_CONFIG_DIR="$TMP/home/config" \
    MISE_STATE_DIR="$TMP/home/state" MISE_CACHE_DIR="$TMP/home/cache" MISE_DATA_DIR="$TMP/home/data" \
    /bin/sh -c "$launch" </dev/null 2>&1
}
actual=$(mise_probe "$WT/sub") || {
  printf 'FAIL: mise refused configs beneath the worktree: %s\n' "$actual" >&2
  exit 1
}
for want in FM_PROBE=root FM_PROBE_LOCAL=local FM_PROBE_SUB=sub; do
  [[ "$actual" == *"export $want"* ]] || {
    printf 'FAIL: mise did not load %s: %s\n' "$want" "$actual" >&2
    exit 1
  }
done
printf 'PASS: mise trusts every config beneath the worktree\n'

if actual=$(mise_probe "$WT-sibling"); then
  printf 'FAIL: mise trusted a sibling directory: %s\n' "$actual" >&2
  exit 1
fi
[[ "$actual" == *"not trusted"* ]] || exit 1
printf 'PASS: trust stays confined to the worktree\n'
