---
name: task-delivery
description: >-
  Agent-only procedure for validating, reviewing, landing, cleaning up, and promoting Firstmate ship and scout work.
  Load before starting or steering validation, on validation or delivery milestones, after a ship or scout reports done, before any merge or local landing, before teardown or scout promotion, whenever the captain adds or changes an ask mid-task (including before validation), and before writing, registering, changing, or retiring a custom `state/<id>.check.sh`.
user-invocable: false
metadata:
  internal: true
---

# Task delivery

This skill owns the conditional path from implementation through a landed ship or completed scout.
The hard rules, captain instruction precedence, unlanded-work protection, and captain-facing communication contract remain always loaded from [`AGENTS.md`](../../../AGENTS.md).
Referenced tools and script headers own exact commands, flags, formats, and data mechanics.

## Selected delivery path and merge authority

The selected delivery path owns its own rigor.
When no-mistakes is selected, no-mistakes owns fixes, tests, documentation, push, PR, and CI.
Every GitHub PR also follows the captain-approved low/high-stakes review ledger owned by `pr-review-policy`; its independent PR review for high-stakes work is the one deliberate addition to the selected delivery path.
Do not stack any other serial manual review or infer one from security, architecture, or risk alone.
The path's worker, automated gates, and captain approval remain authoritative:

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.

Delivery mode and `yolo` are orthogonal.
`yolo` governs ordinary merge authority: with it off, the captain approves every GitLab merge and every local-only landing; with it on, firstmate merges green, in-scope work itself.
The captain-approved GitHub review policy separately authorizes firstmate to merge a PR whose current ledger generation passes every low- or high-stakes gate, while unresolved product, rights, spend, destructive, security-sensitive, or other human decisions still hold it.
Never merge a red PR under either setting unless a current explicit captain instruction names the single GitHub check waived through `fm-pr-merge.sh --allow-red`; that attended-only waiver still requires every other check green.
Destructive, irreversible, and security-sensitive merges still escalate.
Without a current explicit captain instruction that states the concrete merge, the green default stands, and standing `yolo` cannot authorize a red merge.
`AGENTS.md` owns when a current explicit captain instruction overrides a Firstmate-written standing rule within its exact scope.
Load `ask-user-authority` before deciding any ask-user finding; the implementation worker never answers its own finding.
Use `bin/fm-pr-review.sh merge` for every GitHub task PR merge, `bin/fm-pr-merge.sh` directly for GitLab, and `bin/fm-merge-local.sh` for approved local-only landing.
Never call a lower-level merge command around their guards.
After an autonomous merge, give the captain a one-line full-URL or local-main outcome.
Before applying Ready for QA after a GitHub merge or deploy, load `pr-review-policy` and satisfy its head-keyed post-merge gate without weakening any pre-merge browser check.

## Validate

For a no-mistakes ship, trigger validation on the same worker after its implementation commit, using the harness invocation owned by `harness-adapters`.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
When the captain adds or changes an ask mid-task, append the captain's words without added speaker labels or direct address to that brief's `## Captain's intent` and relay those words to the worker.
Firstmate build constraints stay in `## Firstmate spec` or the steer.
[`bin/fm-dod-lib.sh`](../../../bin/fm-dod-lib.sh) owns the worker-side `--intent` contract.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated.
The smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake.
Corrections required to satisfy already accepted intent are not new requirements.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status.
Use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content.
The worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

An ask-user finding returns as `needs-decision`.
Firstmate loads `ask-user-authority` and either decides or escalates per that skill.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command.
Pass `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the resolved state line from `bin/fm-crew-state.sh`, whose header owns outcome mappings and CI-monitor and daemon exceptions; never by shell liveness, the last status event, or a raw run record.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.

## Ready, landing, and teardown

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line.
It records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That refusal means the ready head is still only in the worker's copy, so steer the worker on the commit the refusal names rather than treating it as a stalled merge.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
For a GitHub PR, load `pr-review-policy`, initialize its durable head-keyed ledger, and arm its delayed checkpoint in the existing watcher.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green `fm-crew-state.sh` line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` and a passing current GitHub review-ledger generation are the only standing routine merge authorities.

For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` or `bin/fm-teardown.sh` for a spawned task.
Never hand-compose an `rm` with `$STATE` or `$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, load `backlog-management` to record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`.
Its home must contain no work under way, and forced discard still requires explicit captain authority.

## Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded.
Read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
