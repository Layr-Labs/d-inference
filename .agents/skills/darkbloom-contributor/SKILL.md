---
name: darkbloom-contributor
description: Implement, review, or prepare pull requests in the Darkbloom d-inference repository. Use for code, documentation, configuration, CI, release, or protocol contributions so repository-specific synchronization, documentation, validation, and PR requirements are handled before review.
---

# Darkbloom contributor

Use the repository's instructions as the source of truth:

1. Read `AGENTS.md` and every narrower `AGENTS.md` that applies to files in
   scope.
2. Before editing, inspect the target branch and related open PRs so the change
   is based on current work and has not been superseded.
3. Determine documentation impact from `docs/AGENTS.md` section 7 while
   planning the code change. Update the canonical docs in the same commit
   series; do not wait for review feedback.
4. Preserve the cross-language and release synchronization points in
   `AGENTS.md`. Trace readers, failure cleanup, concurrency, and disconnect
   cleanup when provider registry state changes.
5. Create signed commits and confirm every PR commit is GitHub-verified after
   pushing. Amend and re-sign any unsigned commit before requesting review.
6. Run focused tests while implementing, then the component checks required by
   `Makefile`. Run `make docs-impact-check BASE=<target-branch>` and
   `make docs-check` before pushing.
7. Prepare the PR around the final implementation. Every PR description MUST
   include clearly labeled **Before** and **After** Mermaid figures covering
   both observable behavior and code flow. Make them colorful, readable figures:
   use consistent semantic colors, meaningful shapes and grouping, short labels,
   and a legend or caption where needed. Keep the layout legible at GitHub PR
   width, with sufficient text contrast in light and dark themes; prefer compact
   figures over sprawling diagrams or walls of text. Quote labels containing
   punctuation and use GitHub-compatible Mermaid syntax. Verify the published
   figures actually render on GitHub, not just that they parse locally.
   Include concrete validation commands, interface or migration effects, and
   material limitations.

## Post-push review loop

For an authorized PR contribution or review-fix task, keep following the PR
through the automated reviews triggered by your pushes:

- After each push, refresh the remote head, mergeability, review threads,
  top-level comments, review-run status and CI. Compare successive snapshots;
  an immediate post-push snapshot is not evidence that review has finished.
- Validate each new finding against the current code, callers and tests before
  changing anything. Distinguish valid bugs, already-fixed/outdated findings,
  false positives and requests outside the authorized scope. Use a targeted
  reproduction when the code alone does not establish the claim.
- Fix valid in-scope findings, add meaningful regression coverage, rerun the
  affected checks, and push signed commits. Reply with the finding's disposition
  and concrete code/test evidence; resolve a thread only after verifying the fix
  is on the remote head. Explain false positives rather than changing correct
  behavior to satisfy a bot. Do not silently dismiss uncertain findings.
- Repeat for new feedback and conflicts. Treat an unexpected remote head change
  as another contributor's work: inspect and preserve it before continuing.
- Finish when reviews for the latest head have completed, actionable findings
  are addressed, runnable required checks have settled, and a follow-up snapshot
  shows no new feedback. Poll at a reasonable interval (about 60 seconds), while
  continuing independent work. If progress needs external approval, unavailable
  infrastructure or an out-of-scope decision, report the exact outstanding gate
  and last observed state. Do not claim review/CI completion or continued
  monitoring after ending the session; merging and deployment need their own
  authorization.

If the docs-impact check reports a mapping that does not apply, explain why in
the PR and ask a maintainer to apply the `docs-not-needed` label. Do not bypass
the check locally or weaken the mapping to make one PR pass.
