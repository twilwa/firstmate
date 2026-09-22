# AGENTS.md size audit

This audit inventories the blank-line-delimited paragraphs and contiguous list groups in the 85,533-byte `AGENTS.md` baseline reviewed on 2026-09-22.
The byte column counts each group's content including its terminating newline but excludes the blank separator between groups, so the rows do not sum to the file total.
Headings are listed separately so every baseline group has a stable identifier.
The planned replacement is approximately 33,000 bytes, a reduction of about 61 percent; the implementation should report the measured result rather than treating that projection as a quota.
Stage 2 measured 33,212 bytes, 52,321 bytes and 61.2 percent below the baseline.

Disposition meanings are exact: keep always-loaded, prune as derivable from code or docs, prune as duplicated elsewhere, or transpose to a named skill.
When a group mixes always-loaded safety with conditional procedure, the disposition names the destination and the evidence column identifies the safety stub that remains in `AGENTS.md`.

| ID | Baseline group | Bytes | Disposition | Skill trigger | Existing owner or safety evidence |
|---:|---|---:|---|---|---|
| 1 | `# Firstmate` | 12 | keep always-loaded | Always loaded. | Supervisor contract root. |
| 2 | Supervisor and worker-role boundary | 466 | keep always-loaded | Always loaded. | `bin/fm-dod-lib.sh` emits the worker-role override, but the supervisor must always know its own role boundary. |
| 3 | First mate and captain identity | 91 | keep always-loaded | Always loaded. | Supervisor identity has no conditional owner. |
| 4 | Captain-address and chat-only rule | 1,057 | keep always-loaded | Every chat message. | Required safety boundary; section 9 owns captain-facing style. |
| 5 | Section 1 heading | 36 | keep always-loaded | Always loaded. | Prime-directive navigation. |
| 6 | Delegation and secondmate identity | 515 | keep always-loaded | Every project request. | Core supervisor role boundary. |
| 7 | Hard-rule introduction | 31 | keep always-loaded | Always loaded. | Core safety contract. |
| 8 | Hard rules 1-5 | 2,188 | keep always-loaded | Always loaded. | Required verbatim safety boundaries; `bin/fm-teardown.sh` owns the landed-work test and guarded skills own named exceptions. |
| 9 | Firstmate-repo private and shared material | 719 | keep always-loaded | Every repository mutation. | `firstmate-coding-guidelines` supplements this shared-material boundary. |
| 10 | Section 2 heading | 23 | keep always-loaded | Always loaded. | Compact home-layout navigation. |
| 11 | Operational-home ownership and `FM_HOME` | 579 | keep always-loaded | Always loaded. | `docs/configuration.md` "Operational home layout and state" and `bin/fm-send.sh` header. |
| 12 | Directory-purpose summary | 346 | prune as duplicated elsewhere | None. | `docs/configuration.md` "Operational home layout and state" already states the same top-level purposes. |
| 13 | Exhaustive tracked, config, data, project, and state tree | 19,603 | prune as derivable from code or docs | None. | `docs/configuration.md` owns the top-level layout; producer headers and help own child fields and mutation mechanics. |
| 14 | Status-event truth and captain-memory files | 408 | keep always-loaded | Every state interpretation. | `bin/fm-classify-lib.sh`, `bin/fm-crew-state.sh`, and `docs/configuration.md` own mechanics; the event-versus-current-state warning remains inline. |
| 15 | Section 3 heading | 54 | keep always-loaded | Every session start. | Session-start navigation. |
| 16 | Run session start exactly once | 639 | keep always-loaded | Every session start. | `bin/fm-session-start.sh` header and `docs/sessionstart-nudge.md`; run-once rule remains inline. |
| 17 | Read and trust the complete digest once | 700 | keep always-loaded | Every session start. | `bin/fm-session-start.sh` header; read-once and absent-source meanings remain inline. |
| 18 | Lock-refused read-only posture | 305 | keep always-loaded | Any lock refusal. | Required safety boundary; `bin/fm-lock.sh` and session-start digest supply the diagnostic. |
| 19 | Deferred startup-network mechanics | 846 | prune as derivable from code or docs | None. | `bin/fm-startup-network.sh` header and `docs/configuration.md` own the stage and its result states. |
| 20 | Seven-part digest enumeration | 5,160 | prune as derivable from code or docs | None. | `bin/fm-session-start.sh` header owns ordering and contents; wake acknowledgement remains in the always-loaded supervision section. |
| 21 | Bootstrap consent, tool, and diagnostic rules | 825 | transpose to `bootstrap-diagnostics` | Load on any actionable bootstrap or network-check diagnostic listed in section 13. | Existing `bootstrap-diagnostics` owns responses; install consent and essential-tool boundary remain inline. |
| 22 | Section 4 heading | 35 | keep always-loaded | Always loaded. | Replaced by a concise dispatch trigger stub. |
| 23 | Harness trigger and verified-adapter boundary | 546 | transpose to `harness-adapters` | Load before spawn, recovery, trust, harness skill invocation, lifecycle control, or adapter verification. | Existing `harness-adapters` non-negotiable safety and routing matrix. |
| 24 | Dispatch profiles, quota selection, typed resolution, and effort | 3,538 | transpose to `task-intake` and `quota-array-dispatch` | Load `task-intake` for a new task; additionally load `quota-array-dispatch` for a matched profile array. | `docs/configuration.md` "Dispatch profiles", `bin/fm-dispatch-resolve.sh` header, and existing `quota-array-dispatch`. |
| 25 | Secondmate pins and runtime-backend refusal | 556 | transpose to `harness-adapters` | Load before spawn or recovery. | Existing `harness-adapters`, `secondmate-provisioning`, `bin/fm-spawn.sh`, and `docs/configuration.md` "Runtime backend". |
| 26 | Section 5 heading | 15 | keep always-loaded | Every recovery pass. | Replaced by a concise direct-report recovery boundary. |
| 27 | Reconcile reality after startup | 287 | keep always-loaded | Every session start. | `bin/fm-session-start.sh` digest contract; event-versus-current-state warning remains inline. |
| 28 | Ordinary-worker and secondmate recovery procedures | 639 | transpose to `stuck-crewmate-recovery` and `secondmate-provisioning` | Load for the direct-report conditions listed in section 13. | Existing recovery skills; this-home-only recovery boundary remains inline. |
| 29 | Away recovery behavior | 601 | prune as duplicated elsewhere | None beyond the existing away/quiet triggers. | Section 8's away-mode stub plus the `afk` and `quiet` skills own this behavior. |
| 30 | Section 6 heading | 39 | keep always-loaded | Always loaded. | Compact project and knowledge routing remains inline. |
| 31 | Project add/remove procedure | 571 | prune as duplicated elsewhere | Load `project-management` before add, create, clone, register, initialize, or remove. | Existing `project-management` owns the complete policy. |
| 32 | Secondmate provisioning procedure | 368 | prune as duplicated elsewhere | Load `secondmate-provisioning` for its section 13 triggers. | Existing `secondmate-provisioning`. |
| 33 | Secondmate idle-by-default rule | 320 | prune as duplicated elsewhere | Load `secondmate-provisioning` before secondmate lifecycle work. | Existing `secondmate-provisioning`; the core secondmate identity remains in section 1. |
| 34 | Knowledge-routing introduction | 52 | keep always-loaded | Whenever durable knowledge is captured. | Core memory-placement boundary. |
| 35 | Six-way knowledge-routing list | 652 | keep always-loaded | Whenever durable knowledge is captured. | `docs/architecture.md` "Operational memory routing" and `stow` provide procedures; concise destinations remain inline. |
| 36 | Project memory creation and `/stow` | 626 | transpose to `stow` | Load when `/stow` is invoked. | Existing `stow`, `bin/fm-ensure-agents-md.sh`, and hard rule 1; only the project-memory boundary remains inline. |
| 37 | Section 7 heading | 21 | keep always-loaded | Always loaded. | Replaced by concise task-safety and skill triggers. |
| 38 | Always-loaded lifecycle declaration | 131 | prune as duplicated elsewhere | None. | Exact mechanics are owned by scripts and the new lifecycle skills; core safety remains inline. |
| 39 | Intake heading | 25 | transpose to `task-intake` | Load before classifying, briefing, or dispatching a new task. | New skill becomes the conditional policy owner. |
| 40 | Project resolution | 364 | transpose to `task-intake` | Before task classification. | `data/projects.md` is the registry and the new skill owns judgment. |
| 41 | Secondmate routing and avoid-premature-automation rules | 756 | transpose to `task-intake` | Before task classification or routing. | `secondmate-provisioning` owns secondmate mechanics; new skill owns intake judgment. |
| 42 | Existing-evidence preflight | 116 | transpose to `task-intake` | Before commissioning an investigation. | New skill owns task-shape classification. |
| 43 | Ship and scout definitions | 585 | transpose to `task-intake` | Before choosing ship or scout. | `bin/fm-brief.sh`, `bin/fm-spawn.sh`, and `bin/fm-scout.sh` headers own mechanics. |
| 44 | Informational, diagnostic, and implementation-authority boundary | 598 | transpose to `task-intake` | Before scoping informational, diagnostic, or implementation work. | Existing `diagnostic-reasoning`; the new skill owns ship/scout choice. |
| 45 | Delivery mode and yolo intake | 989 | transpose to `task-intake` | Before every ship dispatch. | `bin/fm-project-mode.sh`, `docs/configuration.md`, and task spawn headers own mechanics. |
| 46 | Concurrency, dependency, and brief requirement | 687 | transpose to `task-intake` | Before dispatching or serializing work. | New skill owns intake judgment; `bin/fm-brief.sh` owns scaffold mechanics. |
| 47 | Dispatch heading | 37 | transpose to `task-intake` | Before spawn. | New skill route. |
| 48 | Spawn isolation and backlog transition | 770 | transpose to `task-intake` | Before spawn. | `bin/fm-spawn.sh` header and generated brief own the isolation checks and transition. |
| 49 | Steering, control, remote correlation, and supervision handoff | 1,737 | transpose to `harness-adapters` and `task-intake` | Load before steering or worker lifecycle control. | `bin/fm-send.sh`, `bin/fm-control.sh`, `bin/fm-pending-reply-lib.sh`, and existing `harness-adapters`. |
| 50 | Delivery-path heading | 47 | transpose to `task-delivery` | Load when implementation starts or a delivery milestone arrives. | New skill route. |
| 51 | Selected-path rigor | 539 | transpose to `task-delivery` | Before starting validation or delivery. | No-mistakes, `pr-review-policy`, and the selected-mode scripts own their mechanics. |
| 52 | Three delivery-mode definitions | 402 | transpose to `task-delivery` | Before starting validation or delivery. | `bin/fm-dod-lib.sh` and `bin/fm-project-mode.sh` own generated mode semantics. |
| 53 | Merge authority, red-check waiver, ask-user, and guarded merge commands | 1,671 | transpose to `task-delivery` with always-loaded safety stub | Before any merge or local landing. | Hard rules 1-3 remain verbatim; `pr-review-policy`, `bin/fm-pr-merge.sh`, and `bin/fm-merge-local.sh` own guarded decisions. |
| 54 | Validate heading | 13 | transpose to `task-delivery` | Before validation. | New skill route. |
| 55 | No-mistakes ownership and mid-task scope changes | 1,284 | transpose to `task-delivery` | Before starting or steering validation. | `bin/fm-dod-lib.sh`, no-mistakes, and new skill policy. |
| 56 | Validation invalidation and custody recovery | 1,255 | transpose to `task-delivery` | When a captain instruction invalidates active validation. | No-mistakes structured status and new skill policy. |
| 57 | Ask-user return flow | 599 | transpose to `task-delivery` | On any no-mistakes ask-user finding. | Existing `ask-user-authority`, `bin/fm-send.sh --resolve-key`, and new skill policy. |
| 58 | Validation-state interpretation | 884 | transpose to `task-delivery` | On validation status or wake. | `bin/fm-crew-state.sh` and no-mistakes structured status. |
| 59 | PR ready, landing, and teardown heading | 36 | transpose to `task-delivery` | On ready, merged, or teardown milestones. | New skill route. |
| 60 | PR registration, review ledger, custom checks, and merge signal | 1,389 | transpose to `task-delivery` and `pr-review-policy` | On a PR-ready line or before a GitHub merge. | `bin/fm-pr-check.sh`, existing `pr-review-policy`, `bin/fm-check-register.sh`, and `bin/fm-check-unregister.sh`. |
| 61 | Landed-only teardown | 393 | transpose to `task-delivery` with always-loaded safety stub | Before teardown. | Hard rule 3 remains verbatim; `bin/fm-teardown.sh` owns the complete landed-work test. |
| 62 | Secondmate retirement | 269 | prune as duplicated elsewhere | Load `secondmate-provisioning` before retirement. | Existing `secondmate-provisioning` and hard rule 3. |
| 63 | Scout heading | 32 | transpose to `task-delivery` | On scout completion or promotion. | New skill route. |
| 64 | Scout completion, captain-call gate, visual loop, and promotion | 1,145 | transpose to `task-delivery` and `captain-hold-lifecycle` | Load on scout completion, visual-review completion, or promotion. | Existing `captain-hold-lifecycle`, `bin/fm-promote.sh`, and new skill policy. |
| 65 | Section 8 heading | 27 | keep always-loaded | Always loaded. | Supervision navigation. |
| 66 | Always-loaded supervision declaration | 203 | keep always-loaded | Whenever supervision is required. | Emitted session-start protocol and named docs own harness recipes. |
| 67 | Exactly one live supervision cycle | 555 | keep always-loaded | Whenever work or Relay requires supervision. | Required no-turn-ends-blind contract; `docs/turnend-guard.md`. |
| 68 | Drain-first and generation-bound wake acknowledgement | 1,409 | keep always-loaded | Every wake-handling turn. | Required wake acknowledgement boundary; `bin/fm-wake-lib.sh` prints the exact command. |
| 69 | Wake-handler introduction | 36 | keep always-loaded | Every actionable wake. | Core routing table. |
| 70 | Four wake-type handlers | 819 | keep always-loaded | Every actionable wake. | `bin/fm-classify-lib.sh` and emitted supervision protocol own mechanics. |
| 71 | Bearings contribution trigger | 176 | transpose to `bearings` | Load on contributions wake or upstream-issue filing. | Existing `bearings`. |
| 72 | Merged-clone refresh and Relay terminal behavior | 414 | transpose to `fmx-respond` except clone-refresh stub | Load `fmx-respond` on Relay-linked milestones or terminal wakes. | Guarded fleet sync owns refresh; existing `fmx-respond` owns public follow-up. |
| 73 | Secondmate idleness, silent waits, and scoped watcher repair | 478 | keep always-loaded | Every supervision wait or repair. | `secondmate-provisioning` and emitted supervision protocol; no-broad-kill safety remains inline. |
| 74 | Guard backstop and worktree isolation | 523 | keep always-loaded | Every supervision cycle. | `docs/turnend-guard.md`, `bin/fm-spawn.sh`, and generated ship brief. |
| 75 | Away/quiet heading | 34 | keep always-loaded | When away or quiet markers or commands appear. | Trigger stub must be visible before skill load. |
| 76 | Away and quiet triggers | 512 | keep always-loaded | On `/afk`, `/quiet`, marked injections, or away-state markers. | Existing `afk`, `quiet`, and `bin/fm-wake-lib.sh`. |
| 77 | Away and quiet safety list | 1,610 | keep always-loaded | Whenever away or quiet mode is active. | Required inline safety facts from the `firstmate-coding-guidelines` model stub. |
| 78 | Stuck-worker heading | 25 | prune as duplicated elsewhere | None. | Section 13 already carries the complete skill trigger. |
| 79 | Stuck-worker pointer | 161 | prune as duplicated elsewhere | Load `stuck-crewmate-recovery` for its section 13 trigger. | Existing section 13 row. |
| 80 | Section 9 heading | 39 | keep always-loaded | Every captain-facing message. | Captain communication navigation. |
| 81 | Outcome-first, standalone-final, and vocabulary rules | 1,936 | keep always-loaded | Every captain-facing message. | Core visibility and translation contract. |
| 82 | Internal-to-captain vocabulary map | 1,286 | keep always-loaded | Every captain-facing message. | Core translation table. |
| 83 | Never relay raw internal evidence | 439 | keep always-loaded | Every captain-facing message. | Core confidentiality and translation boundary. |
| 84 | Escalation structure | 269 | keep always-loaded | Every escalation. | Core captain-facing contract. |
| 85 | Immediate-escalation introduction | 35 | keep always-loaded | Every escalation decision. | Core escalation list. |
| 86 | Immediate-escalation list | 368 | keep always-loaded | Every escalation decision. | Core authority and safety boundary. |
| 87 | Parent channel, no-op response, decision asks, PR URLs, and cost | 1,809 | keep always-loaded | Every captain-facing result. | `docs/secondmate-parent-channel.md` owns routing mechanics; response rules remain inline. |
| 88 | Section 10 heading | 24 | keep always-loaded | Always loaded. | Replaced by a concise backlog trigger stub. |
| 89 | Queue, captain-call, transition, and reevaluation policy | 1,494 | transpose to `backlog-management` | Load before filing, holding, handing off, updating, or closing backlog work and on backlog review. | `bin/fm-tasks-axi.sh`, `bin/fm-captain-hold.sh`, spawn/teardown transitions, and existing `captain-hold-lifecycle`. |
| 90 | Backend syntax and cross-home handoff | 490 | transpose to `backlog-management` | Before any backlog command or cross-home handoff. | `.tasks.toml`, `docs/configuration.md`, `tasks-axi --help`, and `bin/fm-backlog-handoff.sh`. |
| 91 | Task-note hygiene | 596 | transpose to `backlog-management` | Before replacing a task note. | New skill becomes the policy owner; tasks-axi owns command syntax. |
| 92 | Section 11 heading | 23 | prune as duplicated elsewhere | None. | Briefing becomes part of `task-intake`. |
| 93 | Captain intent, Firstmate spec, and scaffold ownership | 1,201 | transpose to `task-intake` | Before writing or changing a task brief. | `bin/fm-brief.sh` and `bin/fm-dod-lib.sh` own syntax and intent provenance. |
| 94 | Ship isolation, Firstmate skill, and Herdr lab | 540 | transpose to `task-intake` | Before writing a ship brief; additionally load `firstmate-coding-guidelines` for Firstmate shared material. | `bin/fm-brief.sh` generated safety contract and `firstmate-coding-guidelines`. |
| 95 | Charter brief and status semantics | 338 | transpose to `task-intake` and `secondmate-provisioning` | Before charter briefing or status-protocol customization. | Existing `secondmate-provisioning`, `bin/fm-classify-lib.sh`, and scaffold. |
| 96 | Section 12 heading | 19 | keep always-loaded | Always loaded. | Compact self-update trigger remains inline. |
| 97 | Self-update propagation and skill trigger | 481 | prune as duplicated elsewhere | Load `updatefirstmate` when invoked or requested. | Existing `updatefirstmate` owns the guarded procedure and surface scope. |
| 98 | Section 13 heading | 35 | keep always-loaded | Always loaded. | Central trigger index. |
| 99 | Trigger-index introduction | 82 | keep always-loaded | Always loaded. | Trigger semantics must be visible without loading a skill. |
| 100 | Existing agent-only skill trigger list | 3,820 | keep always-loaded | At each listed condition. | Existing internal skill descriptions; add rows for every new skill. |
| 101 | Section 14 heading | 13 | keep always-loaded | Always loaded. | Replaced by a concise Relay trigger and authority stub. |
| 102 | Relay activation and public authority boundary | 620 | transpose to `fmx-respond` with always-loaded safety stub | Load on Relay wakes or before a promised public reply. | Existing `fmx-respond` owns public-channel authority; `docs/configuration.md` owns activation. |
| 103 | Relay supervision and terminal follow-up | 489 | prune as duplicated elsewhere | Load `fmx-respond` on Relay wakes and linked milestones. | Existing section 13 trigger and `fmx-respond`. |
| 104 | Promised-final durability and owning-home rule | 478 | transpose to `fmx-respond` | Before promising a public final or on public-followup/startup commitment input. | Existing `fmx-respond` and `bin/fm-public-followup.sh`. |
| 105 | Captain precedence heading | 34 | keep always-loaded | Always loaded. | Core authority navigation. |
| 106 | Current explicit captain instruction precedence | 874 | keep always-loaded | Every authority decision. | Core authority and destructive-action boundary. |
| 107 | Maintenance heading | 25 | keep always-loaded | Always loaded. | Compact maintenance trigger remains inline. |
| 108 | File-maintenance discipline | 365 | transpose to `firstmate-coding-guidelines` | Load before changing shared tracked material. | Existing `firstmate-coding-guidelines` owns placement, one-owner, size, trigger, and prose rules. |

## Planned conditional owners

- `task-intake` will own project resolution, ship/scout choice, delivery-mode selection, dispatch-profile intake, concurrency judgment, brief authoring, spawn handoff, and steering boundaries.
- `task-delivery` will own selected-path validation, validation supersession, ask-user return flow, ready-state registration, guarded landing mechanics, landed-only cleanup procedure, and scout promotion.
- `backlog-management` will own backlog backend use, captain-call filing, automatic-transition expectations, cross-home handoff routing, reevaluation, and task-note hygiene.
- Existing `harness-adapters`, `quota-array-dispatch`, `bootstrap-diagnostics`, `stuck-crewmate-recovery`, `secondmate-provisioning`, `captain-hold-lifecycle`, `pr-review-policy`, `fmx-respond`, `stow`, and `updatefirstmate` retain their current precise procedures rather than receiving duplicate prose.

## Safety retention checklist

- Hard rules 1-5 remain verbatim.
- The captain-address rule remains always loaded.
- The lock-refused posture remains always loaded and read-only.
- The generation-bound wake acknowledgement remains always loaded.
- Merge authority remains protected by hard rule 2, the captain-precedence boundary, a concise task-lifecycle stub, `task-delivery`, and the exact guarded merge owners.
- Unlanded-work protection remains protected by hard rule 3, the captain-precedence boundary, a concise task-lifecycle stub, `task-delivery`, and `bin/fm-teardown.sh`.
- The full supervision cycle and away/quiet safety stub remain always loaded.
