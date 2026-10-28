#!/usr/bin/env bash
# Compose the worker command's mise trust environment from its resolved directory.
# No global trust store or invoking-process environment is read or modified.

fm_launch_mise_env() { # <resolved-worktree> <launch-command>
  # Single-quote for the destination shell, including literal apostrophes.
  local quoted="'${1//\'/\'\\\'\'}'"
  # The pane shell, fish included, parses only test, &&, || and export here;
  # inherited trust expands in the destination shell, after filtering.
  # shellcheck disable=SC2016
  printf '[ -n "$MISE_TRUSTED_CONFIG_PATHS" ] && export MISE_TRUSTED_CONFIG_PATHS="$MISE_TRUSTED_CONFIG_PATHS":%s || export MISE_TRUSTED_CONFIG_PATHS=%s; %s' \
    "$quoted" "$quoted" "$2"
}
