Live validation of bin/fm-lint.sh local-run memory bounds (branch fm/plat-fm-lint-local-bound, 0a71f200 vs base 78e5cce).
All fixture runs used disposable git repos under /tmp (bin/fm-lint.sh + its sibling tooling + bin/helper.sh sourced by
bin/consumer.sh + tests/t.test.sh), executed inside `systemd-run --user --scope -p MemoryMax=4G` with CI/GITHUB_ACTIONS/
FM_LINT_REQUIRE_BOUNDS unset unless shown. Where a probe is shown, the `shellcheck` first on PATH was a pass-through wrapper
that logs its own nice value and `ulimit -v` and then execs the real ShellCheck 0.11.0 binary.
The `awk ... bin/backends/*.sh` line is a fixture artifact (no bin/backends/ in the fixture) and appears identically on base.
Files:
  s1-s3-selection.txt               sourced-helper / lint-definition change: local stays changed-only; hosted --changed still upgrades
  s4-s5-local-main-and-refusal.txt  local on main lints changed-only; no merge-base / no git => exit 2 refusal pointing to sandbox/CI
  s6-s9-cap-and-nice.txt            default local run: 1 worker, each root nice 10 under ulimit -v 12582912 (base: 2 workers, nice 0, unlimited)
  s6b-tiny-cap-fails-by-name.txt    8 MiB cap: root fails by name (signal:SEGV) locally; base ignores the cap and passes
  s6-s7-cap-enforced-and-budget.txt budget: --jobs 2 / FM_LINT_JOBS=2 / 20 GiB cap refuse; FM_LINT_LOCAL_MEMORY_BUDGET_GIB=24 allows 2; hosted unaffected
  s8-cap-unavailable-refusal.txt    hard RLIMIT_AS 8 GiB or missing watchdog: local --partition refuses; changed set notes and lints
  s10-hosted-inventory-real-repo.txt real repo: hosted --list-files (651) == union of 4 partitions; bare CI=true is local
  s11-real-repo-gate-lint.txt       real repo gate-form lint: 3 roots, jobs 1, bounds_enforced 1, peak RSS 326 MiB, 13 s
  fm-lint-workflows-test.log / fm-lint-test.log  focused tests from the author's verification plan, capped scope
  focused-tests-attempt1-killed-at-10min.log     first attempt via fm-test-run.sh under nice -n 10, stopped at the 10-min tool limit (no result)
