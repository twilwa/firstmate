#!/usr/bin/env bash
# bin/fm-kimi-delivery-lib.sh - the Kimi Code CLI brief-delivery evidence over
# one plain pane capture. Sourced by bin/fm-spawn.sh's Kimi delivery gate and by
# the live guards tests/fm-kimi-trust-prompt-live-e2e.test.sh and
# tests/fm-kimi-delivery-live-e2e.test.sh, so one owner answers "has Kimi taken
# a submitted message" for every recorded release.
#
# The signals are vendor-rendered, so any one of three independent signs
# carries the verdict and no single string is load-bearing:
#   - the transcript echo of the brief pointer: `✨` somewhere on the pane with
#     the pointer text on 2.0.0 (2026-09-17), and a row led by `❯` then the
#     pointer text on 2.3.x (2.3.3 recorded 2026-10-27,
#     tests/captures/kimi-code-2.3.3/README.md). Kimi's composer draws `>`
#     inside its box, so a pointer still sitting in the composer matches
#     neither shape;
#   - a nonzero context-usage percentage, which 2.3.3 shows only a few
#     seconds into the turn;
#   - Kimi's moon-phase turn spinner, through the delivery-only matcher
#     bin/fm-composer-lib.sh owns (fm_busy_lines_match kimi), which the caller
#     must already have loaded, as every fm_backend_source does.
# A pointer dropped during Kimi's startup input window shows none of them.
# Composer emptiness is a separate veto the caller reads through the shared
# composer classifier, because a pointer still in the composer is not delivered
# whatever else the pane shows.

# kimi_pane_shows_brief_taken <plain-pane-capture>
kimi_pane_shows_brief_taken() {
  local pane=$1
  case "$pane" in
    *'✨'*'Read the brief at'* | *'Read the brief at'*'✨'*) return 0 ;;
  esac
  printf '%s\n' "$pane" | grep -Eq '^[[:space:]]*❯[[:space:]]+Read the brief at' && return 0
  printf '%s\n' "$pane" |
    grep -qiE 'context:[[:space:]]*(0\.[0-9]*[1-9][0-9]*|[1-9][0-9]*([.][0-9]+)?)[[:space:]]*%' && return 0
  printf '%s\n' "$pane" | fm_busy_lines_match kimi
}
