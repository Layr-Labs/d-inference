# Enable and operate international bank withdrawals

> Last updated: 2026-09-05 · commit `4d9811f7c`

This runbook enables Stripe Global Payouts alongside existing Connect withdrawals. Providers use one bank setup and withdrawal flow. Country selection chooses the payout product; international withdrawals include a local-currency estimate before confirmation.

## When to use

Enable bank withdrawals for supported destinations outside the current Connect route, or reconcile an international withdrawal. Country policy is `coordinator/billing/globalpayouts/countries.go` (`Countries`): 33 countries use Connect for new destinations and 67 use Global Payouts when enabled. Existing ready Connect accounts remain on their route. Mainland China, Cambodia, and Gibraltar have no new-account route in this policy because account-specific support or bank requirements remain unverified.

## Prerequisites

- The reviewed coordinator and console changes are built. Follow [coordinator deployment](coordinator-deploy.md) for the specific human-approved production operation. Local PostgreSQL, API-fixture and UI tests cover accounting and integration behavior; real Stripe acceptance and bank delivery are separate checks.
- Stripe has accepted the business/funds flow for Global Payouts. Its legal responsibilities differ from Connect; see [Stripe's product comparison](https://docs.stripe.com/global-payouts/compare-with-connect).
- A restricted API key has Recipient Configuration Write, Money Management Financial Accounts Read, Money Management Payout Methods Write, and Money Management Outbound Payments Write, including recipient-context permissions required by Stripe. Hosted Account Links access is also required. Do not grant all Money Management permissions. [Stripe key requirements](https://docs.stripe.com/global-payouts/send-money)
- Read back the key's account identity and financial account. Verify the chosen financial account is open, belongs to the expected business, and has usable funding. The ordinary Payments balance is not the Global Payouts funding balance.
- Configure a signed event destination for Global Payouts outbound-payment events at `POST /v1/billing/stripe/global/webhook`. The signing secret is separate from Connect. The minute-based reconciler is a backstop, not a reason to omit event delivery.

## Steps

1. Deploy the code with `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ENABLED` unset or false. This preserves legacy onboarding and withdrawals. The migration only creates new tables/indexes; it does not modify earned balances or existing Connect withdrawal rows.
2. Configure the restricted key (or use the existing restricted Stripe key), financial-account ID and event signing secret using the [configuration reference](../reference/configuration.md#billing-stripe-and-base-rewards). Keep keys out of logs, shell command arguments and review artifacts. Key permission expansion and production configuration changes require their applicable approval.
3. Set `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ENABLED=true` and recreate the coordinator using the deployment runbook. Enabled configurations require the financial account and API key; funding and account permissions must be checked before this step.
4. In the billing or provider earnings page, choose India and complete Stripe-hosted recipient onboarding. This collects the bank details directly with Stripe. The Pay via Email shortcut is domestic-only and is not used by this implementation.
5. Verify `GET /v1/billing/stripe/status?refresh=1` returns `payout_rail=global`, country `IN`, a bank destination, `status=ready`, and local currency `inr`. Readiness includes active recipient capability and an eligible bank payout method, not merely a submitted form.
6. Review an explicitly authorized withdrawal. Confirm that the quoted local amount, USD debit, withdrawal fee and destination match. Quotes do not debit the ledger. Confirm once and retain the internal withdrawal ID for reconciliation.
7. Verify the resulting outbound-payment ID and bank arrival independently. `posted` is displayed as **Sent to bank**, because it does not prove the bank has released funds. Confirm the ledger debit once and actual bank credit before declaring the route verified.
8. Review international payout fees and rejection/return patterns as other supported countries onboard. The implementation keeps the user-facing standard withdrawal fee at zero; Darkbloom pays Stripe's payout charges. Corridor limits and bank eligibility are checked by Stripe when generating the quote. Additional country-specific capabilities or verifications must be resolved before treating that route as verified.

## Verify

The source-of-truth payout row is `global_payout_withdrawals` and its `data` object. Quote state is `quoted`; a confirmed withdrawal atomically debits both balance columns and moves to `pending`. Stripe then supplies `processing`, `posted`, `failed`, `canceled`, or `returned`. Refunds are atomic with the state update and applied once. State cannot regress from posted to processing or reopen after a refund (`coordinator/store/global_payouts.go`, `applyGlobalResult`).

Each internal quote ID identifies at most one confirmed withdrawal. Retries use its persisted Stripe idempotency key and immutable request. Pending withdrawals with no outbound-payment ID stop resubmitting after 12 hours. After an ambiguous first attempt, subsequent API errors do not automatically refund: changed permissions or funding configuration must not cause a refund when money may already have moved (`coordinator/api/global_payouts_reconcile.go`, `syncGlobalPayout`).

Inspect without exposing the stored request or recipient information:

```sql
SELECT id, status, external_id, submitted_at, checked_at,
       data->>'failure_code' AS failure_code,
       data->>'refunded' AS refunded,
       data->>'dispatch_attempts' AS dispatch_attempts
FROM global_payout_withdrawals
WHERE status <> 'quoted'
ORDER BY submitted_at DESC
LIMIT 50;
```

## Troubleshooting

- **403 from Stripe:** inspect exact key permissions. Do not rotate unrelated credentials or substitute a broad secret key.
- **Country absent:** reconcile the live account's menu and API capability with `Countries`. Public documentation alone does not establish account entitlement.
- **Quote rejected:** no withdrawal is submitted. Check destination requirements, bank eligibility, currency, limits, required payee verification and funding access.
- **Unknown send result:** use the internal ID and `gp-withdraw-<id>` to find the original Stripe request. Do not independently pay from the Dashboard or credit the ledger before establishing the outcome.
- **Posted but no bank credit:** use the Stripe payout detail and bank trace. Posted is not a guaranteed delivery receipt.
- **Returned:** confirm Stripe's current state. The signed webhook or reconciler restores earnings once. Do not add a second manual refund.

## Rollback

Set `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ENABLED=false` to stop new international onboarding, quotes and confirmations while retaining the configured API key, financial account and event secret. The reconciler, event handler and retries of already-submitted withdrawals continue. Do not drop the new tables, erase withdrawal records, rotate the original idempotency keys, or unlink funded Connect accounts. Code rollback to a build without Global Payouts likewise requires continued reconciliation of already-submitted payouts.

## Related

- [Billing architecture](../architecture/billing.md)
- [API contracts](../reference/api-contracts.md)
- [Stripe Global Payouts status semantics](https://docs.stripe.com/global-payouts/manage-payouts)
