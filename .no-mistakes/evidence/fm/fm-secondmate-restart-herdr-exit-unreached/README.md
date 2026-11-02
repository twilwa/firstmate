# Live Herdr lab: Claude /exit with the slash-completion popup open

Setup: a fully isolated Herdr universe (XDG_CONFIG_HOME=<lab>/xdg, herdr 0.9.5) with its own disposable default server, and
an fm-lab-* session created, provisioned, viewed (40x120 viewer) and torn down only through bin/fm-herdr-lab.sh.
Real Claude Code 2.1.316 runs in the lab pane. A marked lab FM_HOME (bin/fm-lab-home.sh) holds a herdr task record `smlab`.
The real Herdr universe (default stopped; firstmate and wS0 running) was snapshotted before and after: identical.

| File | What it shows |
|---|---|
| fm-control-exit-base.txt | base 39710ce7: `fm-control.sh smlab exit` -> "error: the exit command could not be sent to task smlab on herdr" (the reported failure) |
| pane-snapshots-base.txt | the composer `❯ /exit` above the selected popup row `  ❯ /exit   Exit the CLI` during that send; Claude still alive afterwards |
| fm-control-exit-target.txt | target a5b6b944, same pane and Claude: `stopped smlab ... endpoint=...:w3:p1 worktree=...` |
| pane-snapshots-target.txt | the same popup geometry during the target send, then the shell prompt after Claude exits |
| fm-control-relaunch-target.txt | target: `fm-control.sh smlab relaunch` (the transaction fm-secondmate-restart.sh runs) -> `relaunched smlab ...` in the same pane |
| fm-control-exit-target-after-relaunch.txt | target: exit of the relaunched agent after a conversation turn -> `stopped` |
| ordinary-text-submit-target.txt | target: ordinary text through fm_backend_send_text_submit is proven and submitted (Claude replied PONG) |
| real-herdr-sessions-{before,after}.json | real fleet Herdr sessions unchanged |
