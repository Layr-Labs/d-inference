# Maintain a pull-request stack

> Last updated: 2026-10-06

How to keep dependent PRs reviewable before approval and restore their ancestry
after a parent is squash-merged. This procedure updates branches, not product
content or repository merge policy, and does not authorize merging PRs.

## Prerequisites

- Use linear bases: the first PR targets `master`; each child targets its
  immediate parent, not `master` or a sibling.
- Have Python 3, Git, authenticated `gh`, repository push access, and a working
  signing identity whose commits verify locally and show as Verified on GitHub.
- Use a non-shallow clone with one identical `origin` fetch and push URL for the
  PR repository. All PRs must be in that repository; fork PRs are not supported.
- Coordinate with branch owners: no affected branch may change during the
  operation, including deletion, rewind, or pushes from another worktree.
- Keep the parent branch and its original head available until restacking is
  verified. Do not delete it immediately after the squash.

## Steps

1. **Refresh before approval.** Fetch current refs and merge each refreshed
   parent into its child, bottom-up, using signed merge commits and non-force
   pushes. Resolve content conflicts and run affected tests. Do this before
   requesting approval: new commits or base changes can dismiss stale approvals.
2. **Wait for the actual squash.** `master` is squash-only. The squash represents
   the parent's content with a new commit identity, not the parent's original
   ancestry. Even a clean pre-merge refresh cannot guarantee no later conflicts.
3. **Check the remaining stack.** From the repository root, pass PR numbers in
   immediate-parent order to `scripts/restack-after-squash.py`:

   ```bash
   python3 scripts/restack-after-squash.py PARENT CHILD DESCENDANT --check
   ```

   Omit `DESCENDANT` when only one child remains; append further descendants in
   order. `--check` is the default. Use `--repo OWNER/REPO` when needed to select
   the repository explicitly. The script uses the merged parent's recorded base,
   not a hardcoded `master` target. Check mode does not test signing or push
   permissions, create commits, or change branches or PR bases.
4. **Review, then publish.** If the check succeeds and branch updates are
   authorized, repeat with `--push`. Add `--retarget` to update the child's PR
   base to the merged parent's base; remaining descendants keep their linear
   relationship:

   ```bash
   python3 scripts/restack-after-squash.py PARENT CHILD DESCENDANT --push --retarget
   ```

   Hooks remain enabled. `--skip-hook` requires explicit human authorization
   for that operation; it is not a workaround for a failed check.
5. **Repeat after each squash.** When the next parent is actually squash-merged,
   run check and push again for that parent and its remaining descendants.
   Do not assume the previous ancestry repair covers future squashes.

## Verify

The script checks the actual squash tree against the original parent's head,
the descendant ancestry, linear PR bases, and current refs before constructing
signed, same-tree ancestry bridges. It publishes with an atomic non-force push;
it refuses content differences rather than choosing a conflict resolution.
These bridges change ancestry without changing each child's content.

After every update, inspect the remote heads and PR bases, verify every new
commit displays as Verified, wait for required CI on the new heads, and recheck
mergeability and approval state. Retargeting is a separate GitHub operation,
not part of Git's atomic push; verify it even if the push succeeded. Ask for
fresh approval when an earlier approval was dismissed.

## Troubleshooting

- **Squash tree or ancestry differs:** stop and reconcile content manually with
  the branch owners, then revalidate. Do not manufacture a same-tree bridge to
  conceal a real change, force-push, or relax repository policy.
- **Refs changed or a push failed:** inspect all remote heads and rerun the
  check before retrying. Atomic non-force push is not an atomic compare-and-swap
  against deletion or rewind; the requirement to keep branches unchanged is
  essential even when a push could otherwise fast-forward.
- **Signing, hooks, CI, or retargeting failed:** repair the failed gate and verify
  remote state. A clean content tree alone is not evidence that the PR is ready.

## Related

- [Contribution rules](../../CONTRIBUTING.md)
- [Build](build.md)
- [Restacking tests](test.md#pull-request-restacking)
