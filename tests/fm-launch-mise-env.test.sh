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
touch "$WT/mise.toml"
launch=$(fm_launch_mise_env "$WT" 'printf "%s" "$MISE_TRUSTED_CONFIG_PATHS"')
actual=$(env -u MISE_TRUSTED_CONFIG_PATHS /bin/sh -c "$launch")
[[ "$actual" == "$WT/mise.toml" ]] || {
  printf 'FAIL: mise.toml not trusted in worker environment: %s\n' "$actual" >&2
  exit 1
}
printf 'PASS: launch trusts the worktree mise config\n'

# Every supported filename is trusted; existing destination trust is preserved.
for config in .mise.toml .mise/config.toml .tool-versions; do
  rm -f "$WT/mise.toml" "$WT/.mise.toml" "$WT/.mise/config.toml" "$WT/.tool-versions"
  mkdir -p "$WT/.mise"
  touch "$WT/$config"
  launch=$(fm_launch_mise_env "$WT" 'printf "%s" "$MISE_TRUSTED_CONFIG_PATHS"')
  actual=$(MISE_TRUSTED_CONFIG_PATHS=/existing /bin/sh -c "$launch")
  [[ "$actual" == "/existing:$WT/$config" ]] || exit 1
done
printf 'PASS: alternate configs retain destination trust\n'

# Include all present configs, not just the highest-precedence one.
touch "$WT/mise.toml" "$WT/.mise.toml" "$WT/.mise/config.toml"
launch=$(fm_launch_mise_env "$WT" 'printf "%s" "$MISE_TRUSTED_CONFIG_PATHS"')
actual=$(env -u MISE_TRUSTED_CONFIG_PATHS /bin/sh -c "$launch")
[[ "$actual" == "$WT/mise.toml:$WT/.mise.toml:$WT/.mise/config.toml:$WT/.tool-versions" ]] || exit 1
# The explicit assignment survives env -i without forwarding ambient trust.
actual=$(/usr/bin/env -i /bin/sh -c "$launch")
[[ "$actual" == "$WT/mise.toml:$WT/.mise.toml:$WT/.mise/config.toml:$WT/.tool-versions" ]] || exit 1
printf 'PASS: all present configs survive filtered launch\n'

rm -f "$WT/mise.toml" "$WT/.mise.toml" "$WT/.mise/config.toml" "$WT/.tool-versions"
launch=$(fm_launch_mise_env "$WT" 'printf "%s" "${MISE_TRUSTED_CONFIG_PATHS-unset}"')
actual=$(env -u MISE_TRUSTED_CONFIG_PATHS /bin/sh -c "$launch")
[[ "$actual" == unset ]] || exit 1
actual=$(MISE_TRUSTED_CONFIG_PATHS=/existing /bin/sh -c "$launch")
[[ "$actual" == /existing ]] || exit 1
printf 'PASS: no config leaves trust unchanged\n'
