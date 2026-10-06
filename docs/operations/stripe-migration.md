# Migrate bank payouts and Checkout to the Darkbloom Stripe account

> Last updated: 2026-09-30

Use this runbook to activate Global Payouts for every supported bank destination,
retain legacy Connect settlement, and move new Checkout purchases independently.
Users complete bank setup themselves. Deploying the PR does not activate cutover,
move cash, issue refunds, or migrate recipient credentials.

## When to use

The existing Global Payouts financial account is funded and approved for the full
provider-earnings, rewards and referral funds flow. All countries in the application
policy can be routed to Global Payouts; the published country list alone does not
establish recipient/bank eligibility. Mainland China and Brazil remain outside
the application's current menu. See [country policy](../../coordinator/billing/globalpayouts/countries.go).

## Prerequisites

- Reviewed code and passing coordinator, PostgreSQL settlement, console and docs
  checks. Follow [coordinator deployment](coordinator-deploy.md).
- Explicit human approval for each production deployment, configuration/permission
  change, cash movement and named historical refund. A refund command is not a
  diagnostic command. Never run repository tests against production.
- Stripe confirmation that the business's complete funds flow is permitted under
  [Global Payouts responsibilities](https://docs.stripe.com/connect/cross-border-payouts#compare-integrations).
- Verify the intended account identities in Stripe and, where permitted, with
  `GET /v1/account`. Verify the exact Global Payouts financial account is open and
  funded using its v2 read API. A positive business-account balance is not a
  positive Payments balance; changing API keys does not move money.
- Preserve the existing Global Payouts key, financial-account ID and signing
  secret. Verify recipient-verification permissions and bank eligibility for
  newly served countries, including UK Confirmation of Payee and applicable
  European checks. The hosted form must finish and capabilities must be active.
- Review platform-paid fees, a funding reserve and replenishment ownership. US
  onboarding requests `bank_accounts.local`, not `wire`. The standard user fee
  and minimum are unchanged. The funding precheck includes quoted USD Stripe fees
  but does not reserve external funds against concurrent withdrawals.

## Steps

1. **Deploy compatible code first.** Keep
   `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ONLY=false` while deploying coordinator
   and console. Existing Global Payouts recipients keep their destinations.
   Add no recipient records on behalf of users. Back up configuration and record
   the approved commit, image digest and account identities without credentials.

2. **Separate the legacy credentials before moving Checkout.** Configure
   `EIGENINFERENCE_STRIPE_CONNECT_SECRET_KEY` with the old platform's key. Keep
   `EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET` for its existing destination.
   The cutover disables the fallback from Connect to the primary Checkout key.
   Retain these credentials until old payout obligations are resolved.

3. **Fix event delivery.** On the old platform retain a platform event destination
   for `transfer.reversed` at `/v1/billing/stripe/connect/webhook`. Create a
   destination sourced from **connected accounts** for `account.updated`,
   `payout.paid`, `payout.failed` and `payout.canceled` at
   `/v1/billing/stripe/connect/accounts/webhook`, with its distinct
   `EIGENINFERENCE_STRIPE_CONNECT_ACCOUNTS_WEBHOOK_SECRET`.
   Verify signed delivery and rejection of the wrong secret/source. Keep the
   current Darkbloom Global Payouts destination at
   `/v1/billing/stripe/global/webhook`. Do not replay unverified payloads.

4. **Audit historical withdrawals.** Build the maintenance binary and run it
   with production database credentials supplied securely through the environment:

   ```bash
   go build -o /tmp/payout-audit ./coordinator/cmd/payout-audit
   /tmp/payout-audit --since 2026-09-01T00:00:00Z --limit 50
   ```

   The default command uses a read-only transaction, statement/lock timeouts and
   bounded rows. Its output is internal financial data; store it with restricted
   access. It reports status flags, not proof of missing bank payment or credit.
   For each failed/unrefunded row, inspect the original Stripe request using
   `wd-tr-<withdrawal-id>`, the request log and ledger reference
   `stripe_withdraw:<withdrawal-id>`. A missing transfer ID is not proof that no
   money moved. Unknown outcomes and transfers already created must not be refunded
   using the rejected-transfer path.

   After an operator verifies definitive rejection **before any transfer was
   created**, approves the exact withdrawal and amount, and checks for other manual
   compensations, apply one named refund:

   ```bash
   /tmp/payout-audit --apply-refund "$APPROVED_WITHDRAWAL_ID" \
     --expected-amount-micro-usd "$APPROVED_AMOUNT_MICRO_USD" \
     --verified-stripe-request "$VERIFIED_STRIPE_REQUEST_ID"
   ```

   This command records the operator's assertion; it does not independently query
   or verify Stripe request logs. It compares the exact failure/amount/state again,
   refuses known transfer/payout IDs, and uses the existing reference-idempotent,
   atomic refund transaction. A persistence failure retains the verified rejection
   for retry. New first-attempt rejections receive this marker automatically;
   unverified historical rows do not. Never bulk-promote historical failures.

5. **Resolve old transfers using evidence.** Retain the old connected accounts
   and their bank access. Read the transfer and actual payout/return state; do not
   pay a second time through Global Payouts because the local status is old.
   During cutover, automatic payout events require the exact transfer in the
   payout's expanded balance transactions before marking a row paid. Grant the
   retained key the necessary read permissions for that evidence. Unexpanded,
   refunded or unmatched sources remain unresolved. Redeliver verified events
   where Stripe supports it; older cases need an explicitly reviewed repair.

6. **Activate bank migration.** With the dedicated key, financial-account ID and
   Global Payouts webhook secret present, set
   `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ONLY=true` and keep
   `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ENABLED=true`. Apply the approved deployment
   procedure; `refresh-env.sh --check` verifies the candidate first. The flag
   applies globally, not to an account percentage: after sandbox qualification,
   coordinate initial live verification with consenting users in the US, Canada,
   UK and eurozone before declaring migration qualified.

   Existing Connect users see **Update bank details** and enter their own details
   through the authenticated Stripe-hosted flow. New withdrawals require the new
   recipient to be ready. Old clients receive `bank_setup_required` without a debit.
   Users retain their account, provider setup, earnings and combined history.
   Dormant users finish bank setup when they next withdraw. Resetting setup retains
   the routing fence. No automatic fallback to Connect is allowed for these users.

7. **Move new Checkout purchases.** Configure the primary
   `EIGENINFERENCE_STRIPE_SECRET_KEY` and `EIGENINFERENCE_STRIPE_WEBHOOK_SECRET`
   for the intended Darkbloom account. Set
   `EIGENINFERENCE_STRIPE_LEGACY_WEBHOOK_SECRET` to the old Checkout destination's
   signing secret and keep that destination active. Both destinations use
   `/v1/billing/stripe/webhook`. New purchases use only the primary key; old
   signed sessions settle against their existing database identity. Session and
   ledger updates commit together. Existing credit balances are not moved or reset.
   Stripe-side refunds/disputes and account-level liabilities still belong to the
   account that originally processed each purchase; retain its operational access.

8. **Retire only after reconciliation.** Verify no new Connect accounts/transfers
   are being created, old ambiguous and failed-unrefunded withdrawals are resolved,
   old bank payouts/returns are accounted for, and outstanding Checkout sessions
   have settled or expired. Agree with Stripe which late events and liabilities
   require retaining credentials/destinations. Keep immutable financial history.
   The old Stripe account's negative balance remains its liability and must be
   resolved independently; cutover does not erase it.

## Verification

- Test migration, pause, unlink, wrong-secret, concurrent confirmation, lost-response
  and refund rollback paths locally and in sandbox. Production bank receipt is a
  separate acceptance check; `posted` only means sent to the bank.
- Confirm live `status` returns `payout_rail=global`, no instant-card offer, and
  `migration_required` only while an old Connect user needs bank setup. Merely
  loading status must not create recipients.
- Check one debit per confirmed quote, the actual financial account charged,
  bank receipt and actual fees. Reject unavailable funding before the debit, and
  verify an external rejection/return credits only once.
- Check both old and new signed Checkout deliveries; replaying either must not
  add another deposit. Unknown local sessions require investigation.
- Maintain counters for setup completion, new Connect activity (must remain zero),
  funding failures, failed-unrefunded rows, ambiguous outcomes and unresolved bank
  returns. Determine funding thresholds from actual expected payouts, not total
  historical attempted withdrawals, which can contain retries.

## Rollback

Pause new Global Payouts using `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ENABLED=false`
while keeping `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ONLY=true`, credentials and
event destinations. Pending confirmations and submitted payouts continue to
reconcile; no Connect fallback occurs. Fix forward where possible. Do not deploy
an old binary that treats a reset recipient row as permission to return to Connect.
Do not rotate the original payout idempotency keys or delete the history tables.

Changing the primary Checkout key back does not move sessions between accounts.
Keep both relevant webhook secrets for previously-created sessions. Configuration
rollback and any balance repairs require their own explicit production approval.

## Related

- [Billing architecture](../architecture/billing.md)
- [Configuration](../reference/configuration.md#billing-stripe-and-base-rewards)
- [Global Payouts operation](global-payouts.md)
- [Stripe hosted recipient collection](https://docs.stripe.com/global-payouts/recipient-creation)
