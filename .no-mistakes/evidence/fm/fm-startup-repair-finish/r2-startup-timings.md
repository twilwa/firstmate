# Composed startup timing at de84116 (round 2; scratch FM_HOME copies of the primary home)

| Run | Exit | Wall | User | Sys | start→lock | lock→bootstrap | bootstrap→wake-queue | wake-queue→fleet-state | fleet-state→network-checks | network-checks→end | Deferred network stage | gh-auth | Load (1/5/15) before |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 0 | 97.68s | 18.30s | 69.72s | 1.05s|4.72s|1.06s|87.65s|3.15s|0.07s | 9948ms | 297ms | 5.81, 21.77, 21.04 |
| 2 | 0 | 100.66s | 19.21s | 76.12s | 1.05s|4.73s|1.33s|89.78s|3.46s|0.32s | 10772ms | 356ms | 8.61, 18.24, 19.84 |
| 3 | 0 | 106.28s | 19.34s | 75.50s | 1.05s|4.70s|1.06s|96.50s|2.88s|0.09s | 10885ms | 346ms | 7.81, 15.26, 18.61 |

Stage boundaries: fm-session-start's own FM_SESSION_START_STAGE_FILE sampled every 250 ms; short stages (e.g. supervision-instructions, read-once, context) may coalesce into adjacent spans.
Every run: exit 0 under 120 s; digest complete LOCK→NEXT STEP; zero '●  STARTUP TRUNCATED' banners; zero 'Argument list too long'; empty stderr;
fm-startup-network.sh report = 'completed off the startup path in ~10-11s'; state/home-summary.json (fm-secondmate-home-summary.v1) rewritten during the run;
no leftover state/.herdr-cleanup-locks.* record; scratch state/.lock taken; primary state/.lock untouched (mtime 07:53:59 +0200, owner pid 1606964) before and after.

Scope: each home is a fresh copy of primary state/ (minus lock files), data/ (minus secondmates.md and worktrees/), config/; empty projects/; FM_BOOTSTRAP_DETECT_ONLY=1.
Herdr = herdr-guard.sh on PATH: 'status --json' synthesised as running, every other call refused and logged (≈270 refused reads/run, all pane get/read + one workspace list).
The live 'firstmate' Herdr session was never contacted, so pane/workspace reads are unreadable rather than live, and projection cleanup ended at
'workspace discovery failed; preserving every candidate' (fail-safe path). The live-fleet read cost of cleanup/snapshot is therefore not included in these numbers.
Note: run 1's home reset could not delete one read-only data/ subdirectory left from a discarded earlier attempt; its files are identical seed copies and state/ was fully fresh.
