# Activate Bedrock review and conditional merge clearance

> Last updated: 2026-10-03

This runbook provisions repository-specific Bedrock access and enables author
auto-merge after complete security review and ordinary CI. Substantial findings
or unavailable review require an independent human override on the exact commit.

## When to use

Use after the implementation has been reviewed and merged under the existing
approval policy. Do not relax the blanket approval requirement before the exact
trusted workflow rule and live acceptance tests are in place. The implementation
does not change cloud permissions, branch rules or auto-merge settings by itself.

## Prerequisites

- AWS provisioning rights in the selected shared Bedrock account, with model
  entitlement for Sonnet 4.6, Opus 5.5 and Sol 6.1 in the US system profiles.
- GitHub repository and organization ruleset administration.
- Existing state-writer App, signed state branch and funded OpenRouter backup;
  see [review configuration](../developer/threat-model-review.md).
- Reviewed infrastructure in `infra/threat-review/bedrock.json` and merge-rule
  proposal in `infra/threat-review/merge-rules.json`. Confirm the actual immutable
  repository ID and default branch still match the proposal.

## Steps

1. Inventory every repository OIDC consumer before changing subject claims.
   Read `repos/Layr-Labs/d-inference/actions/oidc/customization/sub`. The CloudFormation
   parameter `SubjectPrefix` must equal its observed `sub_claim_prefix`, preserving
   any immutable organization/repository IDs. Inventory remote cloud trusts as
   well as workflow files; the existing Claude workflow also requests an OIDC token.
   If any consumer depends on the old subject, coordinate that migration first.
2. An AWS administrator creates a CloudFormation change set from
   `infra/threat-review/bedrock.json` in `us-east-1`, in the intended Bedrock account.
   Review it, then execute it with named-IAM acknowledgement. The stack creates
   three tagged application inference profiles and one restricted role, reusing
   the existing GitHub OIDC provider. It grants no raw-model invocation without
   the matching application-profile condition, no model subscription, and no IAM
   management to the runtime role. Do not reuse the template repository's profiles.
3. After resolving existing OIDC consumers, configure the repository subject as
   `repo,workflow_ref` with `use_default=false`. Confirm the prefix did not change
   unexpectedly. The role trusts only the review and smoke workflow paths at
   `refs/heads/master`, with audience `sts.amazonaws.com`. A feature-branch or
   untrusted PR workflow must not be able to assume it.
4. Set `BEDROCK_SCAN_ROLE_ARN` from stack output `RoleArn`. Set repository variable
   `BEDROCK_SCAN_PROFILES` to JSON mapping `sonnet`, `opus`, `sol` to their respective
   profile ARN outputs. Set `BEDROCK_SCAN_AWS_REGION=us-east-1`. Retain bounded
   defaults (12 calls, 4,096 output tokens), and keep fork AWS access disabled
   (`BEDROCK_SCAN_ALLOW_FORKS` absent), until a different workload budget has
   been approved. No AWS access key is stored in GitHub.
5. Dispatch **Bedrock review smoke test** on master. It makes at most six small
   paid requests, two per model, with no OpenRouter fallback. Check each model's
   source/integration production schema validation, including the boolean
   `needs_deeper_review`, and the request/response usage pairs. The smoke uses
   the scanner's validators with caching disabled and reports each pass's
   escalation flag. Schema compatibility is not security clearance; a `true`
   flag requests further review.
   Independently exercise STS denial from a feature-branch workflow identity and
   denial of direct foundation-model invocation. Positive smoke execution alone
   does not prove either denial or the `pull_request_target` identity.
6. Enable `BEDROCK_SCAN_ENABLED=true` while leaving clearance enforcement off.
   Exercise the actual PR workflow with harmless synthetic authorization-removal
   and restoration commits in a test PR. Check findings, source citations,
   incomplete-review handling, and explicit OpenRouter fallback using a bounded
   test fixture. Close the synthetic PR without merging its vulnerable commit.
   Verify all three model API contracts; model availability alone is insufficient.
7. Install the organization rule proposed in `infra/threat-review/merge-rules.json`
   while preserving all existing protections. It requires the exact master-branch
   workflow, binds ordinary CI checks to GitHub Actions, and requires an up-to-date
   branch. A named security check alone can be forged by a PR workflow and is not
   sufficient. Confirm the GitHub plan supports exact required workflows and any
   Actions-sharing requirement before proceeding. Do not broaden private-repo
   sharing or add bypass actors as an incidental setup step.
8. Set `THREAT_REVIEW_REQUIRE_CLEARANCE=true`. Verify the matrix below on the
   actual required workflow before replacing the existing blanket approval rule.
   Pending rollout, keep every PR subject to the existing human approval.
9. Once acceptance tests pass, update only the default-branch approval policy:
   set the blanket approving-review count to zero and turn off unconditional
   last-push/unattributed-change approval requirements. Preserve resolved-thread,
   signed-commit, deletion, force-push, squash-only, and access-control rules.
   If the existing rule also covers release branches, first preserve its old
   approval requirements in a separate rule for those branches; do not weaken
   their approval policy. Enable the repository's **Allow auto-merge** setting.
   Authors with the necessary repository permissions can then select auto-merge;
   the scanner never merges code itself.

## Verification

| Situation | Required result |
|---|---|
| Complete scan, no medium/high findings, ordinary CI passes | Author can enable auto-merge; low findings remain visible. |
| Medium/high finding or incomplete/failed scan | Security workflow fails until rerun or independent manual override. |
| Changes to `.github/`, `.agents/`, `scripts/`, `infra/`, `AGENTS.md`, or threat definitions | Independent human override required even if the model is clean. |
| Author approval, bot approval, comment, label, stale approval, or missing reason | No override. |
| Reviewer permission revoked or latest approval dismissed | No manual override. |
| Authorized reviewer requests changes | No clearance until that review is addressed. |
| New commit | Old approval and scan cannot clear the new head. |
| Provider timeout, refusal, truncation or invalid JSON | Incomplete; no resampling through the backup. |
| Bedrock unavailable | One explicit OpenRouter route under existing durable backup caps. |
| Usage recording failure | Stop before the next model request. |

To override, a write/maintain/admin collaborator other than the PR author submits
a formal **Approve** review on the current commit with this body, substituting
the full current head SHA and an actual reason:

```text
Security override: <40-character-current-head-sha>
Reason: Explain the reviewed finding or unavailable coverage and why merging is acceptable.
```

Then use **Re-run failed jobs** on that PR's required threat-review workflow.
The rerun verifies current GitHub review state and permissions, skips paid model
calls for a valid override, and records the reviewer and commit in its log.
Findings remain in the PR comment. Normal CI and resolved conversations still
apply. An override cannot make failing builds or tests pass.

The AWS usage artifact contains metadata and token counts, not source or keys.
Reconcile delivered CUR charges by application-profile tags; token counts are
not actual dollar billing. The existing OpenRouter ten-PR/$25 pilot is retained
for fallback and does not auto-renew. Reaching that cap makes backup unavailable;
changing it requires a separate budget decision. Bedrock has a per-attempt call
bound, not that dollar pilot or a repository-wide daily spend cap.

## Rollback

Restore the previous default-branch human approval requirements before disabling
conditional clearance or removing its exact workflow rule. Disable auto-merge
during a policy rollback. Set `BEDROCK_SCAN_ENABLED=false` to return to the
existing OpenRouter route, or `THREAT_REVIEW_ENABLED=false` to stop paid scans.
Cancel active jobs if required; accepted provider calls may still incur charges.
Preserve billing records and the state ledger. Cloud resource deletion is a
separate operation; this runbook does not reset budgets or delete profiles.

## Related

- [Reviewer configuration and limits](../developer/threat-model-review.md).
- [IT template adoption guide](https://github.com/Layr-Labs/bedrock-codescan-template/blob/0abf9843a583d93fb6f9c04ecbb1a0c4425bc117/docs/ADOPTING.md).
- [Bedrock application profiles in CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-bedrock-applicationinferenceprofile.html).
- [GitHub ruleset requirements](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets).
