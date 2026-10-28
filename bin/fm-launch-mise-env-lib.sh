#!/usr/bin/env bash
# Compose the worker command's mise trust environment from its resolved directory.
# No global trust store or invoking-process environment is read or modified.

fm_launch_mise_paths() { # <resolved-worktree>
  local worktree=$1 config paths=''
  for config in mise.toml .mise.toml .mise/config.toml .tool-versions; do
    [ -f "$worktree/$config" ] || continue
    paths="${paths:+$paths:}$worktree/$config"
  done
  printf '%s' "$paths"
}

fm_launch_mise_env() { # <resolved-worktree> <launch-command>
  local paths quoted
  paths=$(fm_launch_mise_paths "$1")
  if [ -n "$paths" ]; then
    # Single-quote for the destination /bin/sh, including literal apostrophes.
    quoted=${paths//\'/\'\\\'\'}
    # Expand inherited trust only in the destination shell, after filtering.
    # shellcheck disable=SC2016
    printf 'export MISE_TRUSTED_CONFIG_PATHS=${MISE_TRUSTED_CONFIG_PATHS:+"$MISE_TRUSTED_CONFIG_PATHS":}%s; ' "'$quoted'"
  fi
  printf '%s' "$2"
}
