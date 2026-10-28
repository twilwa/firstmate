#!/usr/bin/env bash
# Compose the worker command's mise trust environment from its resolved directory.
# No global trust store or invoking-process environment is read or modified.

fm_launch_mise_env() { # <resolved-worktree> <launch-command>
  # Single-quote for the destination /bin/sh, including literal apostrophes.
  local quoted=${1//\'/\'\\\'\'}
  # Expand inherited trust only in the destination shell, after filtering.
  # shellcheck disable=SC2016
  printf 'export MISE_TRUSTED_CONFIG_PATHS=${MISE_TRUSTED_CONFIG_PATHS:+"$MISE_TRUSTED_CONFIG_PATHS":}%s; %s' "'$quoted'" "$2"
}
