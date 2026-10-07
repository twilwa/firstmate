---
name: task-delivery
description: >-
  Folded pointer kept for in-flight briefs: validation, landing, cleanup, and scout promotion moved to upstream's delivery skills.
  Load validation-supervision, ship-landing, or scout-completion instead; this stub only redirects and will be removed one release after the fold.
user-invocable: false
metadata:
  internal: true
---

# task-delivery (folded)

The fork's task-delivery skill was folded into upstream's delivery skills when the fork adopted upstream's `AGENTS.md` structure.
`AGENTS.md` section 7 "Selected delivery path and merge authority" owns delivery rigor, the GitHub review-ledger addition, merge authority, and the guarded merge commands, plus the mid-task ask rule.
`validation-supervision` owns no-mistakes validation, supersession, and ask-user decision delivery; `ship-landing` owns PR readiness, the review ledger hand-off, landing, custom checks, and cleanup; `scout-completion` owns scout reports and promotion.
