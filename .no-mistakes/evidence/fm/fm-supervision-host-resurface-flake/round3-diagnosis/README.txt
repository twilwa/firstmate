Round 3 diagnosis, HEAD 14888572 (unchanged; no tracked edits).
Both runs used the constrained scope (TasksMax=512, MemoryMax=2G, MemorySwapMax=0, RuntimeMaxSec=2700). That scope caps memory and tasks, not CPU.
Per-case timing comes from the sampler.log ok-count timestamps in run1/ and run2/:
  run1 (exit 0, 1516.26s): ok=12@256s ok=32@425s ok=52@783s ok=62@1019s; case 63 (mirror-boundary) took 195s; finished 1479s after the first sample.
  run2 (exit 124, 1800.81s): ok=12@374s ok=32@628s ok=52@1281s ok=62@1692s, so it was about 1.66x slower on every earlier case. Case 63 had run 95s+ when the runner killed the file at 1800s.
  Run2 did not stall in a single wait. The whole file ran slower, and the budget ran out inside the longest case.
I ran the mirror-boundary case alone (a throwaway copy of the test file with step markers, since deleted) in the same scope: rc=0, 332s wall, 311s for the case (run1 took 195s for it).
  Step times (mirror-boundary-probe.log, T=$SECONDS, L=source line): each park_after_stop took 19-27s, made of resurface delivery 5-12s, host exit 4-6s, main_drain_and_ack 6-11s (two fm-wake-drain.sh calls with no wait in them), and park_again 7-11s.
  Handled waits 9-29s, engine-call.3 16s, boundary 15s. No fixed sleep or long poll dominates. Every step is a real event and slows down evenly.
Host load at the probe: load average 34-39 on 12 CPUs (loadavg-at-probe.txt), from work outside this scope.
Conclusion: the measurements show no dead wait in this file. Under host CPU contention every step slows evenly, which is what pushed run2 past 1800s. Nothing here justifies a test edit.
