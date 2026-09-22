Mode: Codex Stop-hook-owned park.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`.
   Until then, the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm belong to the synchronous Stop hook in `bin/fm-codex-stop-park.sh`, never to a model-issued background task.
   Every turn end while supervision is needed keeps `bin/fm-watch-arm.sh` inside that hook's process tree until the watcher closes.
3. An actionable close returns through the same Stop hook as a `FIRSTMATE_OP: v1 watcher:` continuation.
   Run `bin/fm-wake-drain.sh` first, handle the wake, run its exact acknowledgement command, and let the next turn end park again.
   A quiet park returns one `FIRSTMATE_OP: v1 turn-end-guard:` renewal at one quarter of the tracked 86400-second hook timeout.
   That continuation carries no watcher event; let the next Stop establish a fresh park.
4. Never run `bin/fm-watch-arm.sh` after an ordinary wake.
   If it is ever shelled manually, a backgrounded, piped, or bundled command remains denied by the PreToolUse seatbelt in `.codex/hooks.json`.
5. A captain message or cancellation keeps control of the session.
   The active hook retires its tracked arm child on cancellation, and a newer Stop claim supersedes an older park before either can deliver a duplicate wake.
6. Away and quiet mode transfer watcher ownership to their daemon.
   The Stop park stands down while `state/.afk` exists.
7. If the hook reports `TURN WOULD END BLIND`, inspect its registration, session-lock ownership, and watcher startup failure before ending the turn.
   That repair continuation remains bounded by Codex's `stop_hook_active`; it is not a substitute for a healthy park.

The synchronous park is the callback.
A fresh watcher heartbeat without the park proves only recent liveness and never makes ending the turn safe.
