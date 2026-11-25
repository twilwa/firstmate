#!/usr/bin/env bash
# Pass-through shim around the real pinned ShellCheck: logs each invocation's
# flags and root, and (to emulate the hosted runner's ceiling on a small host)
# applies FM_SHIM_SOURCE_AS_KIB as an extra address-space cap only on
# source-following attempts.
real=~/.local/bin/shellcheck
if [ "${1:-}" = --version ]; then exec "$real" "$@"; fi
args=(); root=; seen=0; follow=no
for a in "$@"; do
  if [ "$seen" = 1 ]; then root=$a; fi
  [ "$a" = -- ] && seen=1
  [ "$a" = --external-sources ] && follow=yes
done
printf '%s\t%s\t%s\n' "${root#"$PWD"/}" "$follow" "$*" >> "$FM_SHIM_LOG"
if [ "$follow" = yes ] && [ -n "${FM_SHIM_SOURCE_AS_KIB:-}" ]; then
  ulimit -v "$FM_SHIM_SOURCE_AS_KIB"
fi
exec "$real" "$@"
