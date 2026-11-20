# Live validation: --claude-route (default / direct / direct-code-mode)

Disposable lab: bin/fm-lab-home.sh lab home at /tmp/fmlab.*, checked out at f26fb4fb (and 38ea79f6 for the base
comparison), private tmux socket, tmux backend, toy `notes` project. Every worker below was the real bin/fm-spawn.sh
launching the real Claude Code 2.1.329 CLI with the machine's normal login. User settings point ANTHROPIC_BASE_URL at
the Headroom proxy http://127.0.0.1:8787. The lab was torn down afterwards: tmux server, treehouse pool, lab trust
entries in ~/.claude.json, and /tmp dirs.

- scenario-refusals.log: bad value, codex (direct and default), and secondmate are refused, and no task record is published.
- scenario-control-and-raw.log: a raw launch command is refused. fm-control relaunch refuses a route change or a move
  to codex before stopping the agent (same pid, record unchanged).
- direct-settings.json, direct-relaunch-settings.json, direct-status-pane.txt: direct merges the env block into the single
  --settings value. The worker's /status reads "Anthropic base URL: https://api.anthropic.com".
- rtx-default-status-pane.txt: the default worker's /status reads http://127.0.0.1:8787 (the proxy stays the default).
- rtx-codemode-settings.json, rtx-codemode-status-pane.txt, codemode-pane-scrollback.txt, scenario-codemode-spawn.log:
  direct-code-mode prints the consent notice, and the worker banner reads "Code Mode (experimental) is on". No first-use
  consent dialog appeared. When ~/.claude.json was read after the spawn, codeModeCaveatsAcceptedV1=true was already set;
  no copy of the store from before the spawn exists to confirm the earlier state. The unanswered-dialog path was therefore
  NOT exercised live.
- scenario-relaunch.log, scenario-relaunch-bogus-and-default.log: a relaunch keeps the recorded route. A conflicting
  route, a move off claude, and an unrecognized recorded route are all refused.
- launch-compare.log plus *.norm.sh: the default launch (explicit and absent) is byte-identical to the base-commit launch
  after normalizing the task id, slot, and generation tokens. The only difference for direct-code-mode is the --settings value.
- scenario-dispatch-binding.log: the real fm-spawn.sh, given a hand-written clear data/<id>/dispatch-resolution.json that
  names claude_route=direct, refuses a launch without the route and accepts one with it. The live resolver was not run
  (it is off without a provider key).
- scenario-relaunch.log: run through `fm-spawn.sh --relaunch` after the worker's claude process was stopped by hand. Only
  the refusals in scenario-control-and-raw.log went through `fm-control.sh relaunch`.
- hermetic-tests.log: tests/fm-spawn-dispatch-profile.test.sh plus tests/fm-dispatch-resolve.test.sh under a 900s cap. It
  TIMED OUT (exit=124) after 81 ok lines and no failures, before any claude-route test; it is not evidence.
- hermetic-dispatch-resolve.log: tests/fm-dispatch-resolve.test.sh alone, exit 0, including the claude_route task-record row.
- task-records.txt: the claude_route= line is present only for non-default routes.
