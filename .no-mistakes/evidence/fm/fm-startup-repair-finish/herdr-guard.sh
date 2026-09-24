#!/usr/bin/env bash
# Test guard: never reaches any real Herdr session. `status --json` reports a
# running server (so server_ensure does not poll/start one); every other call is
# logged and refused, so all pane/workspace reads are unreadable.
case "${1:-}:${2:-}" in
  status:--json) printf 'SYNTH ' >> "${FM_TEST_HERDR_COMMAND_LOG:?}"; printf '%q ' "$@" >> "$FM_TEST_HERDR_COMMAND_LOG"; printf '\n' >> "$FM_TEST_HERDR_COMMAND_LOG"
    printf '{"server":{"running":true}}\n'; exit 0 ;;
esac
printf 'BLOCKED ' >> "${FM_TEST_HERDR_COMMAND_LOG:?}"; printf '%q ' "$@" >> "$FM_TEST_HERDR_COMMAND_LOG"; printf '\n' >> "$FM_TEST_HERDR_COMMAND_LOG"
exit 125
