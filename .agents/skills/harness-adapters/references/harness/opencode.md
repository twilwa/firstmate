# OpenCode

Verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4.
OpenCode 2.0.16's model-pinned `mini` launch and isolated worker lifecycle were verified on 2026-09-26; [`runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#opencode-2016-standalone-worker-2026-09-26) holds the version-specific evidence.
The worker adapter requires OpenCode 2.0 or later: its launch uses 2.0's `--standalone` and `mini` forms, and its busy-state plugin exports only the 2.0 default definition.
Primary and secondmate use is unsupported on OpenCode 2.0 until the `fm-primary-*` plugins, which export only the v1 named hook, are ported to the default-definition loader; `../../../bin/fm-spawn.sh` refuses an opencode `--secondmate`.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin latches the worker session on `session.execution.started` and settles it on `session.execution.succeeded`, `failed`, or `interrupted`. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; verified on 2.0.16 during a shell-tool turn, but a long shell command can delay cancellation, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue --standalone` in the same directory; on 2.0.16 `mini` restored earlier messages and processed a manually sent next instruction. Do not assume `--prompt` auto-submits alongside `--continue`. |
| Model flag | On 2.0, the main TUI has no `--model`; pin interactive workers with `opencode mini --model <provider/model> --standalone --prompt`. For an unpinned worker, use `opencode --standalone --prompt`. `run -m provider/model#variant` is headless, not an interactive worker. |
| Effort flag | None for Firstmate's interactive `opencode --standalone --prompt` and `opencode mini` launch verified on 2.0.16; `opencode run` has `--variant`, but that is not this path. |
| Model discovery | On 2.0 `opencode models` accepts no provider positional argument; its empty stdout is not proof an authenticated model is unavailable. Confirm the candidate with a bounded standalone probe. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |

OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.

## Busy-queued Enter

While OpenCode 1.18.4 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

On 2.0.16 `mini`, a queued Enter during a live turn delivered and received its answer in the isolated Herdr lab.
Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.
For the OpenCode 2.0 worker and plugin, run `FM_OPENCODE_ADAPTER_LIVE=1 ../../../tests/fm-opencode-adapter-live-e2e.test.sh` after an upgrade.

## Primary integration

The primary integration was verified on 2026-07-08 with OpenCode 1.17.6.
`.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
In a home with `config/supervision-host` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `client.session.promptAsync`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `tool.execute.before`.
