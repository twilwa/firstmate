Run4 on HEAD 14888572 (no tracked edits). Capped serial whole-file run (TasksMax=512, MemoryMax=2G, MemorySwapMax=0, RuntimeMaxSec=2700, --per-script-timeout-secs 1800), started at load ~18.
The step had to return when only 3 cases had passed and none had failed, so this run gives NO whole-file result.
Once it finishes, exit-code, wall-time and output.log hold the outcome.
Source comparisons against base 23d381e9: pass-assert-statements.diff is empty (447 lines), case-order.diff is empty (72 cases).

RESULT: exit 1 at wall_seconds=1057.27 (runner duration_ms=1056909), 59 ok and 1 not ok, FM_TEST_LISTENERS found=0, max scope tasks 29, scope empty afterwards.
Failure: case 60, test_primary_without_a_verified_mirror_runs_away_only: "not ok - away grok: the host did not stop on TERM".
Both budget-handoff cases passed live (output.log). The run stopped before the resurface case (park_after_stop), so this run says nothing about it.
Cause: L1875 waited for host.rc (the host's real exit) with a fixed 200-poll window. TERM runs the host's cleanup() first: it stops the engine, retires the arm and successor (each with a polled wait), and releases the grant and leases. Bash also holds the trap until any foreground child finishes. Under load the exit took longer than the poll window. This is the same fixed-window problem the review round fixed at the handoff waits.
Fix (fix.diff, unverified live): L1875 now uses wait_for_host_event 60 host_exited, with the same predicate and failure message. The pass/assert lines are still identical to base. A focused live rerun of this case was not done.
