---
name: darkbloom-linear-nightly
description: Reconcile a person's Darkbloom work history with live Linear using the nightly playbook. Update existing issues, create missing deliverables, and route unclear new work to Others. Supports read-only preview and authorized nightly apply runs.
---

# Update my Linear at night

Read the caller’s configuration and state. Use darkbloom-work-history for source
collection. Default to preview unless the caller or configured scheduled prompt
explicitly requests apply and carries the person’s setup authorization.
Every run requires successful refresh output and uses the supplied skill bodies
from its recorded Git revision. If invoked directly without that output, run the
configured dedicated clone's updater first and continue using its returned
instructions. Do not repeat refresh within a run that already supplied it. Stop
before Linear writes if it fails. Do not refresh a product development checkout.

## Start and match

For an apply run, acquire an exclusive local lock in the persistent state folder
before reading or changing state. Manual and scheduled runs use the same lock.
If another run owns it, defer without writing. Do not remove a lock solely because
it is old; establish that its owning run has ended. Release your own lock on exit.
Write state atomically, preserving the last readable version after failure.

Read live Linear identity and verify it matches the configured workspace and
owner. Read the configured team, available issue statuses, and Others project.
If identity has changed or scope cannot be verified, make no Linear writes.
Recover pending writes from state before generating new ones. Freeze the source
time window and gather the person’s work.

Search current projects and issues before creating anything. Prefer an explicit
issue ID or attached PR/branch, then a clear match of deliverable and acceptance
criteria. Search beyond the person’s assigned issues to avoid duplicating a
shared task. Read candidates in full and paginate relevant results. An existing
issue’s project wins over a guess from a repo or chat title; one repo can serve
several projects. Preserve existing assignments, deadlines, priorities,
milestones, cycles, dependencies, and project placement.

If the existing issue belongs to another person, add only a factual contribution
comment when warranted. Do not change that person’s status or take ownership.
If there are several plausible issue matches, record the unresolved match
locally and report it. Do not create a duplicate just to avoid deciding.

If no issue matches a meaningful deliverable, create one assigned to the
configured owner in the configured team. Use a clearly established existing
project when possible. Otherwise use the configured **Others** project and state
briefly why placement is uncertain. Project uncertainty is normal and does not
require nightly clarification. Others is for real unclassified work; an unreadable
source or disputed issue match is not an Others ticket.

## Decide the smallest useful update

Post a concise progress comment only when facts materially changed. Include the
result, useful verification, remaining work or blocker, and durable evidence
links. Research and drafts are valid results when that is the actual deliverable.
Use plain language; no raw logs, private conversation quotes, secrets, local home
paths, or internal reasoning in Linear. Exclude private meeting-derived content
unless the source workflow explicitly allows publication into this destination.

For issues owned by this person, use the team’s existing status meanings:

- Active execution supports In Progress or its equivalent.
- A submitted deliverable awaiting required review supports In Review.
- Done requires evidence that the issue’s acceptance criteria have been met.
  A draft is not publication; passing tests are not deployment; a merged PR does
  not prove a provider feature is available. An implementation-only issue can be
  Done when its own criteria are satisfied.
- A blocker belongs in the comment and an existing blocked state when the team
  uses one. Do not create statuses. Do not regress a status, reopen completed work,
  or remove a blocker without fresh evidence that justifies the change.

Create one issue per accountable deliverable, not one per session, command, or
day. A new issue needs a concrete title, purpose, actual result or remaining
deliverable, observable acceptance criteria, and relevant evidence. Set a status
consistent with the verified work. Do not invent estimates, deadlines, launch
commitments, or tasks that are merely hypothetical ideas.

Preview returns these proposed actions and coverage without mutation. Apply
performs only supported changes within the authorized scope. This playbook does
not publish community messages, send prompts to other chats, or deploy code.

## Make retries safe

Before each mutation, save an action entry locally with its target (or stable
deliverable identity for a new issue), intended fields, supporting source event
IDs, and a stable fingerprint of the new facts. Base the fingerprint on workspace,
owner, target/deliverable, and canonical outcome/evidence identities. Do not base
it on run date, generated prose, or which tool happened to report the work.
Merge duplicated evidence from Codex, Claude Code, and Pi before planning writes.

Put a compact `nightly-linear:<fingerprint>` marker in the automated comment or
new issue description. Check local action history AND current Linear content
before writing. Read all relevant comment pages, including after state loss or
an uncertain response. Skip facts already represented even if phrasing differs.
Do not make a daily comment solely to show that the automation ran.

Read the live target immediately before changing its fields. If another person’s
edit makes the planned change stale, recompute rather than overwrite it. Prefer
adding a progress comment to rewriting an existing description. Patch only the
fields whose changes the evidence supports.

After each write, re-read the issue/comment and verify the content, status,
project, and owner that the action intended to change. Record the resulting IDs
and URLs in state. Track multi-step actions separately: a comment can succeed
while a status update fails.

If a response times out or a write outcome is unknown, find the marker and verify
the target before retrying. Never blindly repeat a create. If recovery reads
cannot establish the outcome, leave it pending and stop dependent writes. Do not
keep retrying writes after an authentication, permission, or unresolved duplicate
error. Complete independent work when it is safe and report the exact problem.

Advance a source’s `last_successful_through` to the frozen `run_through` only when
its window was fully read and every candidate was either reconciled with verified
Linear state, intentionally skipped with a reason, or durably saved as unresolved
work for retry. Keep unresolved work outside the source checkpoint so the next
run attempts it even without new source events. Failed or uncertain mutations
remain pending. A partial/unreadable source retains its old checkpoint; other
complete sources can advance. An empty, completely checked window can advance.
Newly enabled sources start at the configured initial window or an explicitly
chosen backfill date, not another source’s checkpoint.

## Finish

Save minimal state: source checkpoints, action fingerprints and verified Linear
IDs, pending/unresolved work, coverage, and the Git revision for this run. Keep
event pointers local for recovery; do not store raw transcripts. Preserve existing pending work and
retry it before checkpointing new work. Read-only preview never updates this state.

Report verified changes with issue links, count Others items, and identify
unresolved matches or coverage gaps. Separate successful actions from failures.
Stay quiet when there is no new work or actionable problem. If the app requires a
result, return “No new Linear updates.” Missing history is a coverage problem,
not proof that the person did no work.
