# In-house merge queue

This document owns the mechanics and the rationale of Firstmate's in-house merge queue.
`AGENTS.md` section 7 states the landing policy, and the agent-only `ship-landing` skill owns the batch-landing procedure: when to batch, how to pick members, and how to handle a red candidate.
The landing crew's own contract is rendered by `bin/fm-brief.sh --landing-crew`.

## Why an in-house queue

On 2026-10-19 the bbchat queue held 39 open pull requests and landed two to three of them per hour on six self-hosted runners.
Each landing cost about 4.5 full CI runs at about 54 runner-minutes each, roughly 243 runner-minutes per merged pull request.
Those runs came from three sources: one run per fix round, a fresh run every time the default branch was merged into the pull request branch, and reruns for flaky jobs.

A GitHub merge queue was not available, because the repository is private on a plan without it.
A hosted queue would also have to take over merging, which would bypass Firstmate's review ledger and its guarded merge paths.
The queue therefore lives in Firstmate itself, and every merge still goes through those guards.

| Cost per landed pull request | Before | With the queue |
| --- | --- | --- |
| Full runs for intermediate fix rounds | about one per round | none: rounds use the project's scoped feedback run |
| Full runs from refreshing against the default branch | one per refresh | none for a branch that does not conflict |
| Full runs as merge proof | each pull request's own | one candidate run shared by every member, so `1/k` of a run for a batch of `k` |
| Flake reruns | per pull request | per candidate |

For a batch of four, the shared proof costs about 13.5 runner-minutes per member against about 243 before.
The scoped feedback runs for fix rounds are not yet measured, so that column states the shape of the saving rather than a measured total.

## Preconditions

The queue applies to a project only when all of these hold:

- A push to a `fm/batch-<n>` branch runs the project's full merge-proof job set, or that workflow can be dispatched on the branch with `gh-axi workflow run <workflow> --ref fm/batch-<n>`.
- The default branch does not require a pull request to be up to date before it merges, because that setting forces a refresh of every member and defeats the shared proof.

When a precondition fails, land that project's pull requests one at a time through the ordinary `ship-landing` path and tell the captain which precondition blocks the queue.

## Candidate build

The landing crew builds each candidate from the default branch fetched immediately before the build, merging each member at the head commit Firstmate named, in landing order:

```sh
git fetch origin
git switch --no-track -c fm/batch-<n> origin/<default-branch>
git fetch origin "pull/<number>/head"
test "$(git rev-parse FETCH_HEAD)" = "<named head>"
git merge --no-ff --no-edit FETCH_HEAD
```

A member whose fetched head differs from the named head has moved since it was selected, so it is dropped.
A member whose merge conflicts is dropped with `git merge --abort`, and the build continues with the next member.
Batch numbers only increase, so a rebuilt candidate is a new branch and no candidate is ever reset, rebased, or force-pushed.

## Admission and lease

Every push of a candidate is admitted against the project's cap on concurrent full CI runs, and the default branch's own runs count toward that cap.
The captain sets the cap per project; bbchat's cap on 2026-10-19 was two, including the default branch.
Firstmate counts the full-run workflow's queued and in-progress runs with `gh-axi run list --workflow <workflow> --status queued` and `--status in_progress`, and grants a lease only while that count is below the cap.

The crew asks for a lease with a `needs-decision` status line keyed `batch-<n>-lease` that names the candidate head, its base, its members, and anything dropped.
Before granting it, Firstmate checks that every member is still mergeable into the default branch, with `gh-axi api repos/<owner>/<repo>/pulls/<number>` returning `"mergeable": true` (`null` means the forge is still computing it, so ask again), because the forge runs no CI on a conflicting head, so such a member can never show its own green.
A conflicting member leaves the batch, is refreshed alone, and the candidate is rebuilt without it.
Firstmate grants it with a steering message that names the branch and head, sent through `bin/fm-send.sh --resolve-key batch-<n>-lease`, and the grant covers exactly one push of that head.
Where the project carries a pre-push lease hook, the hook enforces the same grant, and the crew never bypasses it with `--no-verify`.

## Proof

The crew pushes with a plain `git push origin fm/batch-<n>`.
Firstmate finds the candidate's run with `gh-axi run list --branch fm/batch-<n>` and accepts it as proof only when the run's head commit equals the leased head and every full-run job passed.
A run on any other commit proves nothing about the batch.

The candidate's green run proves the combination of members on the default branch.
It never replaces a member's own merge guards: each member still needs its own required checks green on its own unchanged head, its current review-ledger generation passing, and the configured merge authority, whether it merges itself or lands inside a batch pull request.
A member whose own head shows a failure that the candidate run disproves, such as a flaky job, gets green by rerunning only that job on its unchanged head with `gh-axi run rerun <id> --failed`, or by a current explicit captain waiver naming that check through `bin/fm-pr-merge.sh`, never by a refresh.

## Landing and cleanup

A proven batch lands in one of two shapes, and the guarded merge path `ship-landing` selects applies to every merge in either one.

- **Member merges.** Firstmate merges the members in landing order, each on its own unchanged head.
  Nothing else lands on that default branch while a batch is landing, so the branch after the last member merges is exactly what the candidate run proved.
  After the last member lands, `git diff --quiet origin/<default-branch> fm/batch-<n>` should report no tree difference after a fresh fetch, and a difference means something outside the batch landed and the proof no longer covers what follows.
- **Batch pull request.** Firstmate opens one pull request from the candidate branch, which carries its own review-ledger generation, and merges it once.
  On 2026-10-20 bbchat's batch pull request https://github.com/twilwa/bbchat/pull/404 carried three members and merged green on its first run.
  A squash or rebase merge leaves the member heads unreachable from the default branch, so the forge keeps every member pull request open.
  Unless the project merges with merge commits, Firstmate then closes each member with `gh-axi pr close <number> --comment "Landed in <batch PR URL> as <default-branch commit>"`.

Every merge moves the default branch, so the next candidate is always built on the default branch as it stands after the latest merge, and a pushed candidate whose base is no longer that head, other than through its own members landing, is rebuilt before it can prove anything.
The crew deletes the remote candidate with `git push origin --delete fm/batch-<n>` on Firstmate's steer and keeps its local branch.
Cleanup of each member's task follows once its pull request is merged or closed as landed, and cleanup of the crew's copy follows its report.

## No refresh without a conflict

A refresh merges or rebases the default branch into a pull request branch.
It changes the head, so it discards that head's green checks and its review-ledger generation and costs another full run.
Refresh a branch only when the forge reports it conflicting with the default branch or a batch dropped it for conflicting with other members; it then revalidates alone and joins a later batch.
