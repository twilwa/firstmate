# Composed startup timing at d89b3ea (scratch FM_HOME copies of the primary home)

| Run | Exit | Wall | User | Sys | start→lock | lock→bootstrap | bootstrap→wake-queue | wake-queue→fleet-state | fleet-state→(network-checks/next-step) | →end | Deferred network stage | gh-auth | Load before |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 0 | 97.24s | 19.04s | 73.59s | 0.78s|4.96s|1.06s|87.41s|2.88s|0.16s| 10070ms | 266ms | 12.77, 17.54, 11.16 |
| 2 | 0 | 90.31s | 18.63s | 72.60s | 1.06s|4.70s|1.08s|80.01s|3.47s|0.00s| 9977ms | 334ms | 6.82, 14.07, 10.66 |
| 3 | 0 | 96.83s | 19.11s | 74.55s | 1.06s|4.96s|1.07s|86.75s|2.87s|0.13s| 10728ms | 312ms | 5.37, 11.85, 10.19 |

Stage boundaries: fm-session-start's own FM_SESSION_START_STAGE_FILE sampled every 250 ms (short internal stages such as supervision-instructions/read-once may coalesce).
Run 2's sampler recorded 'next-step' instead of 'network-checks' for the fifth boundary (network-checks + context took <250 ms).

Per run: digest complete LOCK→NEXT STEP, no STARTUP TRUNCATED banner, no 'Argument list too long',
fm-startup-network.sh report = 'completed off the startup path in ~10s', state/home-summary.json refreshed during the run
(schema fm-secondmate-home-summary.v1), scratch session lock taken; primary state/.lock untouched (mtime 07:53:59, owner live claude pid).

Scope: FM_BOOTSTRAP_DETECT_ONLY=1, empty projects/, data/secondmates.md omitted. Herdr = herdr-guard.sh: status reports a running server,
every other call refused (all verbs attempted were reads: pane get/read, workspace list). The live 'firstmate' session was never contacted and
bin/fm-herdr-lab.sh prepare refused (no running default session), so pane/workspace reads were unreadable rather than live;
projection cleanup exited on 'workspace discovery failed; preserving every candidate'.
Run 0 (startup-run-0-refuse-all-guard-artifact) used a guard that refused status too: fm_backend_herdr_server_ensure polled 10 s per call and the
digest truncated at 120 s in wake-queue - a harness artifact, not the product under realistic Herdr.
