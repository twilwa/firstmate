# Kimi Code CLI 2.3.3 composer and delivery captures

These files are the visible pane of the real Kimi Code CLI 2.3.3 around one brief delivery, each as plain text (`.pane`) and with its styling (`.ansi`).
`../../fm-composer-lib.test.sh` replays them through the shared composer classifier, and the `test_kimi_233_*` cases in `../../fm-kimi-harness.test.sh` replay the plain ones through the fake pane.
They were recorded on 2026-10-27 on Linux with tmux 3.4, from `kimi --auto` launched bare in a 120x40 pane with the operator's own login, model K3.1 Pro, and the updater off (`KIMI_CODE_NO_AUTO_UPDATE=1`), in a directory outside any git checkout.

## Capture provenance

Each capture is `tmux capture-pane -p` output, with `-e` for the `.ansi` files, with trailing blank rows dropped.
Three host details were replaced by text of the same width, so every box border stays where Kimi drew it: the launch directory by `/lab/work` on the welcome box's `Directory:` row and in the footer, the session id by zeros, and the brief path by `/fm-home/data/kimi-lab/launch-brief.md`.

| File | When | What the pane shows |
| --- | --- | --- |
| `ready` | After the folder prompt was answered | The welcome box, the `✦ Kimi K3.1 Pro is ready` notice, `No session yet`, and an empty composer box |
| `pointer-typed` | The pointer typed, before Enter | The pointer inside the composer box after its `>` |
| `submitted` | About 0.4 s after Enter | The pointer echoed as a transcript row led by `❯`, the moon-phase spinner row, an empty composer, and `context: 0% (0/1M)` |
| `working` | About 12 s after Enter, while a shell command runs | Tool rows led by `●`, the spinner, an empty composer, and `context: 3% (20.8k/1M)` |
| `idle-after-turn` | After the turn ended | The reply `● FINISHED`, no spinner, and an empty composer |

In every capture the composer box is followed directly, with no blank row, by Kimi's footer: a mode/model row such as `Never Ask  K3.1 Pro thinking: high  …/lab/work` with a rotating hint on its right, and the right-aligned `context:` row.
The same footer appeared at 60 and 80 columns, with the first row truncated by `…`, and with no login the context row reads a bare `context: 0%`.
A submitted message is never echoed behind `✨`, which is the glyph Kimi 2.0.0 used.

## Replay limits

The replays prove how `bin/fm-composer-lib.sh` and `bin/fm-spawn.sh` read these exact panes.
Whether the installed Kimi still draws them is the question of the live guards: `tests/fm-kimi-trust-prompt-live-e2e.test.sh` for the ready, typed, and refused shapes, which spends no tokens, and `tests/fm-kimi-delivery-live-e2e.test.sh` for a brief that is really taken, which is opt-in.
