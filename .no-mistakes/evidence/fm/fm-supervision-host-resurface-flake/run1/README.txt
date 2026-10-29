Run 1 of 2 (pipeline HEAD 14888572e3664f9e0ea5756aaa206ef399e45e38), constrained serial whole-file run.
Command: systemd-run --user --scope -p TasksMax=512 -p MemoryMax=2G -p MemorySwapMax=0 -p RuntimeMaxSec=2700 -- bash bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1800 --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' --json run.json tests/fm-supervision-host.test.sh
Bus: XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
Start 2026-10-28T22:35:41+01:00  End 2026-10-28T23:00:57+01:00
Exit code: 0   wall_seconds=1516.262825325 (runner duration_ms=1515963 = 25m15.963s; 1800s deadline unchanged)
Result: 73 ok, 0 not ok, skipped_gate=0, FM_TEST_LISTENERS found=0 (output.log, run.json)
Resurface (park_after_stop x4 inside test_undelivered_dialog_is_fed_again_on_the_next_turn): "ok - host: dialog a turn never completed with its report (a park boundary, a stopped turn, no report) reaches the next turn"
Budget handoff first drain (assert_budget_close_after_supervisor_drain): "ok - host+hook: an earlier supervisor drain cannot suppress a queued main-only budget handoff" and "ok - host+hook: failed budget handoff restoration notifies main without starting a successor"
Retirement: sampler.log (5s samples of scope TasksCurrent/procs vs ok count), retirement-per-case.tsv; max scope tasks 33, no growth across cases; scope inactive after run (no leftover processes).
Behavior unchanged vs base 23d381e9: pass-assert-lines.diff empty (528 lines identical, same order); base-pass-messages.txt == head-pass-messages-source.txt (71); base-case-order.txt == head-case-order.txt (72); live-case-order.txt (derived from live ok lines via live-order-check.txt, 0 unmapped) == base-case-order.txt.
Remaining: second complete serial whole-file run on this HEAD (did not fit this round's 30m agent deadline).
