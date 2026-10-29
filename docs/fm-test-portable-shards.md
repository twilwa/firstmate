# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Serial balance hints come from serial runs of the real lanes on `ubuntu-latest`; pool hints come from four-worker runs, as [Pool budget guard](#pool-budget-guard) describes.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, and its hosted run also supplies the current pool hints.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The serial hint table was refreshed on 2026-10-29 from the four newest hosted fork main runs: [40664798225](https://github.com/twilwa/firstmate/actions/runs/40664798225), [40673507764](https://github.com/twilwa/firstmate/actions/runs/40673507764), [40703025845](https://github.com/twilwa/firstmate/actions/runs/40703025845), and [40796972623](https://github.com/twilwa/firstmate/actions/runs/40796972623).
Each hint is the script's slowest successful `duration_ms` across those runs' `fm-test-timing-portable-*` lane artifacts, with the exceptions below.
Per-script run-to-run variance is large on hosted runners: `tests/fm-captain-hold-lifecycle.test.sh` measured between 454829 ms and 671795 ms across those four runs, so a single run's sample is not a packing weight.
That script now runs on a serial shard with the 671795 ms hint (see [Portable pool lane](#portable-pool-lane)).
Run 40703025845 failed only on a cancelled macOS job; every portable lane in it succeeded.
`tests/fm-supervision-host.test.sh` takes only run 40796972623's 517234 ms, because #52 rewrote its handoff waits and the earlier runs measured the old script at about 1046 s.
The refresh covered all 263 serial members and the 25 pool members, whose serial samples come from the serial lanes those runs used before the pool existed; `--estimate-ms` and the scheduling of selections other than the pool read them. An existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
A failed script's duration is excluded even when its lane uploaded an artifact, and a cancelled job's wall time is only a lower bound, so its unfinished or never-started scripts have no completed sample.
Collect successful per-script measurements for every member before calculating a split.
Observed values are packing weights, not an upper bound on future durations.

The supervision host cases run as two scripts, `tests/fm-supervision-host.test.sh` and `tests/fm-supervision-host-late.test.sh`, on one shared fixture, and the wake triage cases likewise split across `tests/fm-watch-triage.test.sh` and `tests/fm-watch-triage-late.test.sh`.
Each suite outgrew a single shard's budget unsplit, and every half now carries an ordinary measured hint from the current refresh.
The first watch-triage script keeps the larger half so it stays its family's longest-hinted member, and it keeps the stock-Bash churn case the macOS lane runs by name.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms Git Bash measurement instead of a portable capability skip.

Hints are not a formality: without one a script packs on the 45000 ms default, which can sit it beside a shard already holding more than eighteen minutes of measured work, so that shard would really have run well past the 20-minute target the guard reserves while the coverage guard still passed.
`test_portable_serial_packing_budget_boundary` now pins every other fixture script to 1 ms, so packing exactly at the 1200000 ms budget is accepted and one millisecond above it is refused even when real serial members have no hint.
The coverage-guard test owns modeled real-hint headroom under that budget.
`tests/fm-backend-t3code.test.sh` and `tests/fm-t3-mcp.test.sh` run in the portable pool, so their values sit in `portable_pool_weight_hints`: every case id the backend suite spawns carries a per-run suffix and its cleanup removes only the `/tmp/fm-<id>` directories that run created, and both suites passed running concurrently with each other and beside another parallel suite (see [`fm-test-isolation-proof.md`](fm-test-isolation-proof.md)).

## Portable pool lane

The `portable-pool` lane is the complete proven-isolated set on one CI job,
run by the production runner under `--jobs 4` bounded concurrency.
The runner refuses `--lane portable-pool` with `--jobs` above `PORTABLE_POOL_WORKERS`, so the CI command cannot run the pool above the proven worker count.
`tests/fm-captain-hold-lifecycle.test.sh` passed the 26-file hosted four-worker proof but ran 1216727 ms there, 81 percent of the 1500-second per-file bound, so it left the proven set and runs on a serial shard. The 25-file hosted rerun measured the slowest remaining member, `tests/fm-pr-merge.test.sh`, at 599407 ms, so every pool member keeps about 2.5x headroom or more under that bound at four workers.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies independently of the lane's installed Pi runtime.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_pool_weight_hints`, which schedule the pool's workers longest-first, and the worker bound in `PORTABLE_POOL_WORKERS`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The lane membership itself is derived from the proven set, so the coverage guard compares the lane against `bin/fm-test-isolation-proof.sh --list` rather than a second literal list.
The CI cap is the dedicated portable tier in [Timeouts](#timeouts) below.

### Pool budget guard

`portable_pool_weight_hints` holds durations measured under four-worker contention, so the guard's makespan models the pool job's wall time rather than a serial floor.
The current values are the per-script `duration_ms` of the 25-file hosted four-worker proof run [40843566303](https://github.com/twilwa/firstmate/actions/runs/40843566303) ([fm-test-isolation-proof.md](fm-test-isolation-proof.md)).
`--check-coverage` models the pool as the four-worker makespan of those hints, packed longest-first, and refuses a makespan above `PORTABLE_POOL_MAX_WEIGHT_MS` (`pool_budget_ms`, 1400000 ms).
It also refuses the ceiling itself unless the 60-second setup allowance plus the ceiling plus the 1500-second per-file bound stays below the pool job timeout (`pool_timeout_min`), so any pool it accepts leaves a hung file room to fail by name.
Today that is 60 + 1400 + 1500 = 2960 seconds against 3000.
`PORTABLE_POOL_TIMEOUT_MINUTES` in `bin/fm-test-run.sh` and the pool job's `timeout-minutes` in `.github/workflows/ci.yml` must agree; `tests/fm-ci-workflow.test.sh` holds them together and checks the same rule against the parsed workflow's per-file bound.
When the guard trips, refresh the pool hints or move work out of the pool rather than raising the timeout.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_pool_stays_fully_hinted_and_bounded`, requires every pool member to have a hint and the modeled makespan to stay inside the budget, and `test_portable_pool_wall_budget_boundary` verifies acceptance exactly at the budget and at the largest ceiling the timeout allows, and refusal one millisecond past either.
Its scheduling regressions also check pool-hint scheduling for the pool and proven-isolated selections and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_pool_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-pool` artifact whenever the pool gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
The longest script, `tests/fm-watch-triage.test.sh`, is the indivisible floor for this layout.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
Each observed completed portable job adds at most 30 seconds beyond its summed scripts in the 2026-09-30 runs [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Even so, a few runs' samples do not establish a P95 or guarantee future headroom.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, using only runs newer than any change that rewrote a script:

```sh
for run in <run-id> <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R twilwa/firstmate --dir "/tmp/fm-serial/$run"
done
find /tmp/fm-serial -name 'fm-test-timing-*.json' ! -name '*aggregate*' \
  -exec jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' {} \; \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort > /tmp/fm-serial/all-hints.txt
# The artifact glob also matches parallel and Herdr lanes; keep only members of
# the serial lane before replacing the table.
join -j 1 \
  <(bin/fm-test-run.sh --list --lane portable-serial | LC_ALL=C sort) \
  /tmp/fm-serial/all-hints.txt
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that the portable-pool lane equals the proven-isolated set.
It also verifies that the pool, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its serial hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards), and its pool wall check in [Pool budget guard](#pool-budget-guard); none of them replaces inspection of actual CI timing artifacts.

## Timing artifacts

The portable pool, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
The runner atomically checkpoints that JSON after each completed file, including timeouts, so completed-file evidence survives if the job is killed while later files are still running.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns four canonical CI partitions, each attempting full source-aware ShellCheck analysis with one worker by default and running workflow validation and backend-purity checks.
Partition packing is longest-first over measured per-root durations in `fm_lint_root_duration_hints`, refreshed from the `*.roots.tsv` telemetry sidecars uploaded as `fm-lint-telemetry-*` artifacts; a root without a measurement packs on `FM_LINT_DEFAULT_ROOT_WEIGHT_MS`.
The current table was refreshed on 2026-10-29 from the sidecars of the same four main runs as the serial hints: [40664798225](https://github.com/twilwa/firstmate/actions/runs/40664798225), [40673507764](https://github.com/twilwa/firstmate/actions/runs/40673507764), [40703025845](https://github.com/twilwa/firstmate/actions/runs/40703025845), and [40796972623](https://github.com/twilwa/firstmate/actions/runs/40796972623).
Each value is the root's slowest completed duration across them: an `end` record with rc 0 and reason `ok` or `memory-fallback`, because a fallback root's real cost includes its retry.
All 560 canonical roots have a sample.
The smaller root sets and sequential workers limit peak ShellCheck memory without dropping any checks.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay, but the current `tests/fm-watch-triage.test.sh` floor alone exceeds that objective.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses nineteen long-lived Linux jobs (thirteen serial, one pool, Herdr, four lint) plus macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one four-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | timing aggregate | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary lint and compatibility lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Portable test | portable pool, portable serial shards | 50 minutes, one value shared by every job in the tier, over a 1500-second per-file bound | Each job runs `bin/fm-test-run.sh --per-script-timeout-secs 1500`, so a hung file fails by name with exit 124 and its output, and the timing artifact still uploads. That happens only if the bound fires before the job cap. Each lane's cap must exceed a 60-second setup allowance plus its packing ceiling plus the per-file bound, and the coverage guard refuses a lane above its ceiling. Serial shard rule: `serial_budget_ms` caps each shard's serial hint sum at 1200 seconds, so 60 + 1200 + 1500 = 2760 seconds against 3000, and a file is covered when it starts within 25 minutes of job start. Pool rule: `pool_budget_ms` caps the four-worker makespan over contended pool hints at 1400 seconds, so 60 + 1400 + 1500 = 2960 seconds against 3000, and the guard also refuses a ceiling that breaks this sum. A file that starts later than its rule allows, because setup overruns its allowance or earlier files overrun their hints, can still hit the job cap as an unexplained timeout. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly four distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, the portable test jobs share one 50-minute cap that obeys each lane's rule above, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
