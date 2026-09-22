---
name: task-intake
description: >-
  Agent-only procedure for resolving, classifying, briefing, dispatching, and steering Firstmate ship and scout work.
  Load before classifying a new project request, choosing ship or scout, selecting delivery mode or dispatch profile, writing or changing a task brief, spawning a ship or scout, or steering its worker.
user-invocable: false
metadata:
  internal: true
---

# Task intake

This skill owns the judgment from a new request through a verified supervision handoff.
The hard rules, captain instruction precedence, and captain-facing communication contract remain always loaded from [`AGENTS.md`](../../../AGENTS.md).
Referenced scripts own exact commands, flags, generated text, and data mechanics.

## Resolve and classify

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.

Route by the nature of the work against each registered secondmate scope, not by a non-exclusive clone list.
Keep `local-only` work in the main home.
Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it; do not read the secondmate's chat because marked routed replies return through its status or referenced document.
If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.
For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.

Before commissioning an investigation, consult existing reports and established evidence.
Classify the deliverable:

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.

If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.
A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.
Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.

## Delivery mode and concurrency

Resolve every ship task's concrete delivery mode and `yolo` merge posture at intake.
Pass the mode explicitly to the brief, and pass both values explicitly to the spawn and any scout promotion; each command refuses to guess the values it consumes.
A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture, and dropping below its rigor needs a reason you can state.
On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
An unregistered project or absent registry resolves to `no-mistakes` with yolo off, and the registration gap goes to the captain.
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.

## Resolve the worker profile

[`AGENTS.md`](../../../AGENTS.md) section 4 owns the `harness-adapters` load trigger and the unverified-adapter rule; that skill owns static-config fallback and reporting.

[`docs/configuration.md`](../../../docs/configuration.md) owns dispatch-profile and runtime-backend schemas, [`bin/fm-harness.sh`](../../../bin/fm-harness.sh) owns static resolution, and [`bin/fm-spawn.sh`](../../../bin/fm-spawn.sh) owns launch flags and fail-closed validation.
When dispatch profiles exist, consult them at every crewmate or scout intake and pass the resolved concrete profile required by `fm-spawn`.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.

Firstmate alone resolves a matched profile array.
Load `quota-array-dispatch` before choosing among one; that skill is the single owner of the current-quota, eligibility, reasoning-class, runway-feasibility, and `spendPriority` procedure.
Preserve malformed profile configuration as an actionable error rather than selecting around it.

Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight.
On `clear`, pass its `profile:` line to `fm-spawn` unless you state a reason to override, then rerun the same script with `--record-dispatch` for the profile you actually dispatched.
`ambiguous`, `escalate`, `error`, and off all mean the judgment-based intake above, unchanged, and record no dispatch; [`docs/configuration.md`](../../../docs/configuration.md) "Typed dispatch resolution" owns the contract.
The generic effort fallback and its precedence are owned by `harness-adapters`; do not add model-specific versions of that policy.

`secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns the harness consequences.
Dispatch only on a backend that `fm-spawn` validates as spawn-capable.
Pass an explicit per-spawn `--backend` only under that exact task's own authority, never as later-task precedent.
A missing dependency, authentication failure, unsupported backend, or version refusal is a blocker; never silently retry on another backend.

## Write the brief

[`bin/fm-brief.sh`](../../../bin/fm-brief.sh) and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then fill `## Captain's intent` (`{TASK}`) with the captain's own ask and any boundary the captain stated, plus the context needed to read it, including the substance of any report, decision, or PR the ask refers to.
Never widen the ask there into a general goal or an enumerated coverage list, because the reviewer treats that subsection as acceptance criteria.
Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with only the build instructions that ask requires, naming what stays out of scope when the ask is narrow.
A generalization, consistency sweep, or extra hardening the captain did not ask for is follow-up work to note, not scope to add.
[`bin/fm-dod-lib.sh`](../../../bin/fm-dod-lib.sh) owns intent authoring without added speaker labels or direct address, its provenance markers, what a no-mistakes worker may pass as `--intent`, and the string's self-sufficiency rule.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.

Every ship brief must retain the worktree-isolation assertion and stop if launched in the primary checkout.
If a ship task touches Firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
The generated Herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle action.

Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
Status appends are sparse supervisor-actionable events, not routine progress; [`bin/fm-classify-lib.sh`](../../../bin/fm-classify-lib.sh) owns keyed open and resolved semantics.
The scaffold is a safety contract, not a suggestion.

## Spawn and hand off supervision

Spawn only through `bin/fm-spawn.sh` after the profile and backend checks above.
The spawn must resolve a genuine isolated task worktree distinct from the primary checkout; a failed isolation assertion stops the task.
When the configured tasks-axi backlog gate applies, the spawn itself moves the work item to In flight and refuses rather than dispatching work this home has no item for.
A manual-backend home retains the hand-editing contract in `docs/configuration.md`.
After spawning, confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.

Steer a worker with ordinary text through fail-closed `fm-send`.
The message becomes a durable record in the task's steering inbox, and the worker's terminal receives only a constant doorbell line.
[`bin/fm-task-inbox-lib.sh`](../../../bin/fm-task-inbox-lib.sh) and [`bin/fm-send.sh`](../../../bin/fm-send.sh) own inbox and typed-plane mechanics.
A remote secondmate steer uses the same durable-inbox model.
After an unconfirmed delivery, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe because it preserves the request body for remote enqueue deduplication.
When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes that decision record at answer time.

`fm-send` is the data plane for text the worker should read.
Never use its key or text paths for interrupt, exit, or other lifecycle control, because routing-marked lifecycle text becomes chat the worker reasons about instead of executing.
Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns the per-runtime mechanics, verifies each action, and never tears down or discards anything.
A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
[`bin/fm-pending-reply-lib.sh`](../../../bin/fm-pending-reply-lib.sh) owns parent-side correlation, recovery, and escalation for marked secondmate requests.
After the handoff, follow the always-loaded supervision contract in `AGENTS.md`.
