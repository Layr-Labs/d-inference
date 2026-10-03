# Bedrock provisioning — 2026-10-03

Provisioned from PR1325's reviewed CloudFormation starting point. Sonnet5.5 is now
enabled and has passed restricted source/integration validation, restoring the
original requested selection alongside Opus5.5 and Sol6.1. This handoff does not
activate the scanner or change merge protections.

## Configuration applied

Account: `188847976460`; region: `us-east-1`.

Stack: `d-inference-threat-review`, status `UPDATE_COMPLETE`.

Stack ARN:
`arn:aws:cloudformation:us-east-1:188847976460:stack/d-inference-threat-review/76e47ec0-bf49-11f1-af5b-0afff63d21e5`

Repository Actions variables have been set and read back:

- `BEDROCK_SCAN_ROLE_ARN=arn:aws:iam::188847976460:role/d-inference-threat-review`
- `BEDROCK_SCAN_AWS_REGION=us-east-1`
- `BEDROCK_SCAN_PROFILES` maps the aliases below to the full application profile ARNs.

| Alias | Final source profile | Dedicated application profile |
| --- | --- | --- |
| `sonnet` | `us.anthropic.claude-sonnet-5-5` | `arn:aws:bedrock:us-east-1:188847976460:application-inference-profile/xozi5e4a29tj` |
| `opus` | `us.anthropic.claude-opus-5-5` | `arn:aws:bedrock:us-east-1:188847976460:application-inference-profile/8dyqpjhdjkiy` |
| `sol` | `us.openai.gpt-6.1-sol` | `arn:aws:bedrock:us-east-1:188847976460:application-inference-profile/8xbmmz0i0p7o` |

Sonnet5.5 initially reported agreement `NOT_AVAILABLE` and a restricted invocation
returned `AccessDeniedException`, so Sonnet4.6 was tested as a temporary alternative.
After the owner confirmed enablement, all four availability axes read ready and
Sonnet5.5 passed both production-schema calls. The final profile above replaces
the temporary Sonnet4.6 profile, whose absence was verified. No Marketplace
agreement was created by this agent. Scanner and OpenRouter identity are restored
to Sonnet5.5 with the original $2/$10 per-million-token provider ceilings.

## Trust and permissions

The repository subject configuration is `use_default=false`,
`include_claim_keys=["repo","workflow_ref"]`, `use_immutable_subject=false`.
The existing prefix `repo:Layr-Labs/d-inference` is preserved.

The role allows audience `sts.amazonaws.com` and only these exact subjects:

```text
repo:Layr-Labs/d-inference:workflow_ref:Layr-Labs/d-inference/.github/workflows/threat-model-review.yml@refs/heads/master
repo:Layr-Labs/d-inference:workflow_ref:Layr-Labs/d-inference/.github/workflows/bedrock-smoke.yml@refs/heads/master
```

Runtime permission is only `bedrock:InvokeModel` on the three dedicated profiles
and their regional foundation-model ARNs in us-east-1, us-east-2, and us-west-2.
Foundation-model access requires a matching `bedrock:InferenceProfileArn`.
No static AWS credential was added. The deployed trust document, invoke policy,
profile configuration, model request receipts and policy simulations are embedded
in [deployment-20261003.json](deployment-20261003.json).

## Validation

Each final model completed a source assessment and integration call using the
production SYSTEM, INSTRUCTIONS and full response schema from PR1325 commit
`f924d268783f2bd7add8239ee59ebed19d7a85f6`, including boolean
`needs_deeper_review`. All six responses had unique request IDs, `end_turn` and
valid token usage. Sol's integration returned `needs_deeper_review=true`; these
checks establish format compatibility, not security-review clearance.

Live model tests used a temporary operator-assumed role with the same invoke
statements as the production role and an additional explicit Marketplace deny.
That role and its inline policy were deleted after validation. Direct raw-model
calls returned `AccessDeniedException` for all final models. Independent policy
simulation of the actual production role confirmed profile access and denial of
raw-model access without profile context. This is not yet a successful assumption
of the production role from a master workflow: Anto's post-merge smoke covers that.

A real feature-branch GitHub token using the new subject template was denied by
STS with HTTP403/`AccessDenied` in
[run37138288308](https://github.com/Layr-Labs/d-inference/actions/runs/37138288308).
Its exact subject and request ID are in the JSON evidence.

The unchanged Claude workflow successfully exchanged GitHub OIDC for its App
token both [before](https://github.com/Layr-Labs/d-inference/actions/runs/37137932327)
and [after](https://github.com/Layr-Labs/d-inference/actions/runs/37138260867) the
subject change. Both full jobs failed later because the existing Anthropic API
key returned HTTP401/`API key is invalid`. That pre-existing credential issue
needs separate repair; OIDC migration did not cause it. The temporary validation
issue1334 is closed, and the test branch is not proposed for merge.

The exact effective master merge rules were read before and after and compared
unchanged. PR1325 remains draft/unmerged. Existing OpenRouter and state-writer App
secrets were not replaced.

## Quotas, budget and ownership

Applied US cross-region quotas read on2026-10-03:

| Model | Tokens/minute | Requests/minute |
| --- | ---: | ---: |
| Sonnet5.5 | 6,000,000 (`L-94A31E46`) | Not found in the inspected applied inventory |
| Opus5.5 | 30,000,000 (`L-A4430697`) | Not found in the inspected applied inventory |
| Sol6.1 | 40,000,000 (`L-8C5F762B`) | Not found in the inspected applied inventory |

Sol's listed daily quota carries an explicit exception for approved TPM increases;
do not treat its 28.8B displayed value as an unconditional additional limit.

The existing account budget is USD1M/month filtered to Amazon Bedrock. It is not
a repository spending cap and does not cover observed Marketplace-billed usage.
No repository dollar cap has been approved/configured here. No email alert was
added. The owner selected Eigen Dashy; live dashboard ingestion and CUR billing
reconciliation remain separate from these provisioning checks. Billing ownership
has not yet been confirmed. The shared profile/role CostCenter tag is
`security-engineering`; that tag does not establish an accountable billing owner.

Token evidence covers successful responses only. The initial denied Sonnet5.5
attempt retains unknown usage. The JSON preserves the earlier Sonnet4.6 validation
separately from the current Sonnet5.5 evidence: eight successful calls across the
validation history, six for the final model selection. Historical alternative
ledger `production_model` named the upstream request while `source_model` identified
Sonnet4.6; both fields match Sonnet5.5 in the new successful validation.

## Anto's remaining rollout

1. Incorporate the production-schema smoke and updated deployment handoff into
   PR1325, then follow existing review and merge protections. The model selection
   now matches the original Sonnet5.5, Opus5.5 and Sol6.1 request.
2. Run the master-only smoke against all three profiles, then validate the actual
   PR review flow and OpenRouter fallback.
3. Handle scanner activation and merge-policy rollout separately, and confirm
   billing ownership and any desired repository spending policy.
4. Repair the existing Claude Anthropic API credential independently.
