# Run a model token promotion

> Last updated: 2026-09-18 · commit `e64b9df42`

Configure a one-time token grant for eligible individual accounts that explicitly claim before the deadline and campaign cap. Grants never expire, work across the account's API keys, and switch to paid credit after exhaustion. Model registration is a separate step.

## When to use

Use for a launch such as 150 million Bonsai 2 input-plus-output tokens for the first 250 eligible accounts to claim, or another model, allowance and cap. The promotion can be configured before that model exists in the catalog. Prefer the eventual public model ID so alias build changes remain covered.

## Prerequisites

- A reviewed coordinator and console containing the promotion APIs and additive migrations.
- Admin access through `scripts/admin.sh`. Production configuration and activation require human approval for that operation.
- The exact model ID, claim dates, last eligible signup date, claim cap, IANA timezone, and platform model price. No promotion is activated by installing this code.

## Steps

1. Generate a reviewable payload, substituting the agreed launch date:

   ```sh
   python3 scripts/model-token-promotion.py \
     --model-id ternary-bonsai-2-27b \
     --date YYYY-MM-DD --signup-cutoff-date YYYY-MM-DD \
     --claim-through YYYY-MM-DD --timezone America/Los_Angeles \
     --tokens 150000000 --max-claims 250 > /tmp/bonsai-promotion.json
   ```

   The helper only prints JSON. It converts local calendar dates to exact instants, including daylight-saving transitions. The claim start is inclusive and the end exclusive. Signup eligibility is strictly before midnight following the configured last signup date. Users must sign in and click Claim; login and page loads never allocate a slot. The first configured number of eligible accounts to successfully claim receive a grant.

2. Review the JSON and, after approval, configure the promotion:

   ```sh
   ./scripts/admin.sh raw PUT /v1/admin/token-promotions @/tmp/bonsai-promotion.json
   ./scripts/admin.sh raw GET /v1/admin/token-promotions
   ```

   Reapplying the same model, quantity, signup cutoff, claim cap and window is idempotent. Only `enabled` can subsequently change. There is one promotion per model; changing its quantity or dates returns `409 promotion_conflict` and cannot reset already-issued grants. Use another model ID for another model promotion.

3. Register/publish the model separately using [model-migration.md](model-migration.md). A grant neither advertises a model nor bypasses its admission, capacity, authentication, rate-limit or trust gates.

4. Set or verify model pricing. Sponsored tokens pay providers at exact platform model pricing without a request minimum. Fractional micro-dollar earnings carry per provider account and become withdrawable as whole units accumulate; splitting requests cannot enlarge the subsidy. Provider custom prices do not enlarge sponsored earnings. Fully paid requests after exhaustion retain ordinary pricing. Serving your own sponsored request gives neither a provider payout nor a token deduction.

5. Verify the model's first-content SLA. The exact Bonsai IDs already select a 10-second upstream base and 5 ms per estimated input token. The coordinator retains its 1-second response margin, so its cutoff is 9 seconds plus 5 ms/token. Other models keep their existing policies. An explicit deployment override can configure another model before registration:

   ```sh
   EIGENINFERENCE_MODEL_FIRST_CONTENT_SLAS='my-model=10000:5'
   ```

   This affects the existing request-absolute first-content clock, including routing/queue time; it is not a separate pure-kernel prefill timer. See [configuration](../reference/configuration.md).

## Bonsai launch draft

`deploy/promotions/bonsai-2-20260918.json` is prepared, not applied:

| Setting | Value |
|---|---|
| Model ID | `ternary-bonsai-2-27b` (confirm when registering) |
| Grant | 150,000,000 input plus output tokens; no expiry after claim |
| Claim cap | First 250 eligible accounts; one claim per account |
| Eligible signups | Before September 19, 2026 at 00:00 America/Los_Angeles (through September 18) |
| Claim window | September 18 at 00:00 through September 19; closes September 20 at 00:00 America/Los_Angeles, or when the cap is reached |

The window does not automatically shift if deployment is delayed. Review the dated payload before approval or regenerate it for a newly agreed window. Model registration and applying this JSON remain separate operations. Frontend chat explicitly enables thinking by default; this is independent of whether the user has claimed a promotion.

## Verification

- Sign in with eligible and ineligible accounts; listing offers must not allocate grants. `POST /v1/me/token-promotions/claim` uses Privy auth and a `{"model_id":"..."}` body; `GET /v1/me/token-promotions` shows the account's grants. Repeated claims must not increase `claimed_count` or `total_tokens`, or reset `used_tokens`. Race more eligible claimants than the cap: only the first successful allocations may claim; the rest receive `409 promotion_sold_out`. Accounts created at or after the signup cutoff receive `403 promotion_ineligible`.
- Test the selected model with a zero paid balance. The consumer's usage cost is zero while the linked provider receives normal platform-priced earnings.
- Check partial exhaustion with funded paid credit. Free tokens cover input first, then output; uncovered tokens use paid credit and the ordinary request minimum. Provider payout covers the full request.
- With no available free or paid credit, expect `402 free_tokens_exhausted`. A request whose maximum token budget exceeds the remaining free tokens and paid balance returns `402 promotion_balance_required`; lower `max_tokens`, wait for active reservations, or add credit.
- Retry, cancel, and simulate a coordinator restart. Used grants remain durable. Active requests renew reservations; ten minutes without renewal allows orphan recovery, including paid-hold refunds. A recovered hold rejects late settlement and cannot double-pay.
- Run the local checks described in [developer/test.md](../developer/test.md). Verify a signed provider and the intended hosted path separately before launch.

## Rollback

Reapply the original payload with `enabled: false` to stop new claims. Existing grants remain usable and do not expire. Removing the console banner does not revoke grants. Do not roll the coordinator back to a binary that ignores grants while promotional traffic is active: it would charge that traffic normally. Keep the additive tables and reconcile active reservations before any broader rollback.

## Related

- [Billing architecture](../architecture/billing.md)
- [Pricing model](../reference/pricing-model.md)
- [Consumer billing](../consumer/billing.md)
- [API contracts](../reference/api-contracts.md)
