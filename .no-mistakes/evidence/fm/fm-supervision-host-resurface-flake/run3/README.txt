Round 4 Test-step evidence, pipeline HEAD 14888572e3664f9e0ea5756aaa206ef399e45e38 (same head as run1/ and run2/; no tracked edits since).

No whole-file run this round. Host load was about 38 on 12 CPUs at start, from agents outside this run (loadavg-start.txt). On this same head, run1 took 1516s and run2 hit the 1800s deadline. That is more than the agent's remaining 30-minute budget, so a whole-file run started now would have been cut off. Still owed: a second complete serial whole-file run (run1 is the one completed green so far).

Focused live run (focus-driver.sh). The real test file was copied, with the host_cases array cut down to the budget-handoff and resurface cases (focus-copy.diff; copy kept as focus-copy.test.sh.txt and removed from the worktree). It ran through bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1800 inside systemd-run --user --scope with TasksMax=512, MemoryMax=2G, MemorySwapMax=0 and RuntimeMaxSec=2700.
  exit 0, wall_seconds=326.04 (runner duration_ms=325423), FM_TEST_LISTENERS found=0, skipped_gate=0 (output.log, run.json)
  ok - host+hook: an earlier supervisor drain cannot suppress a queued main-only budget handoff
  ok - host+hook: failed budget handoff restoration notifies main without starting a successor
  ok - host: dialog a turn never completed with its report (a park boundary, a stopped turn, no report) reaches the next turn   (this case runs park_after_stop, the resurface delivery and handback)
Retirement: sampler.log has 5s samples of scope pids and watcher/host processes, keyed by ok count; retirement-per-case.tsv. After the last case: tasks=9, watcher_or_host_procs=0. The scope was gone right after the run (scope_gone).
Unchanged assertions vs base 23d381e9:
  pass/expect_code/assert_* statement lines: base == head, 440 lines (pass-assert-lines.diff empty); with fail lines added, 441 lines (pass-fail-assert-statements.diff empty)
  case order: base top-level calls == head host_cases array, 72 cases (case-order.diff empty)
  fail messages (fail-messages.diff): the only change splits "the watcher's downtime resurface did not reach main" into "did not deliver this park's downtime resurface" and "the delivered downtime resurface did not reach main". That is the intended delivery-then-handback split.
Adversarial predicate check (predicate-check.sh/.txt; HEAD functions extracted verbatim): a missing log, only an earlier park's row, an unrelated row and a prefix-only row are all rejected; only a new rearm-resurface row is accepted. wait_for_host_event returns rc=1 after its elapsed bound and returns as soon as the event happens.
Note: line 3 of output.log, "rm: cannot remove /tmp/fm-supervision-host.tP9zow", is about a stale fixture dir created during run1 (birth time 1793224009), not by this run. It was removed afterwards.
