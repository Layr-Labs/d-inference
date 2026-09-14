# Billing: pricing, reservations, ledger, and payouts

> Last updated: 2026-09-14 · commit `5ac94bb27`

Darkbloom is prepaid. A consumer account holds an integer micro-USD balance;
the coordinator reserves the worst-case cost of a request before dispatch,
settles the provider-reported cost after the terminal message, and credits the
provider a withdrawable share that it withdraws through Stripe. Connect and the Global Payouts adapter share the earned-balance ledger. This
page explains the money path and what it guarantees. Constants, formulas,
routes, and env vars are tabulated in
[`reference/pricing-model.md`](../reference/pricing-model.md); the consumer
how-to is [`consumer/billing.md`](../consumer/billing.md).

## Context

- **Prepaid, reservation-first.** There is no post-paid billing. A request is
  admitted only after its worst-case cost is debited (or held), so a provider
  can never be owed money the consumer does not have. The reservation bound is
  what makes the `max_tokens` ceiling mandatory
  (`coordinator/api/consumer.go`, `defaultMaxOutputTokens` comment).
- **One unit.** Every balance, price, reservation, and ledger row is an
  `int64` in micro-USD (1 USD = 1,000,000 µUSD). Prices are µUSD per
  1,000,000 tokens. Stripe is the only boundary where amounts become integer
  cents (`coordinator/api/billing/checkout_webhook.go` `StripeWebhook`
  multiplies `AmountTotal` by `10_000`; `coordinator/api/billing/amounts.go`
  `microUSDToCents`).
- **Accounts.** A consumer is an API-key account or a Privy user
  (`coordinator/api/requestauth/identity.go` `ResolveAccountID`). A provider
  machine earns only when linked to an account (`registry.Provider.AccountID`).
  The literal account `platform` holds platform prices and platform-fee
  credits. `users.role = "service"` (`coordinator/store/contracts/users.go`
  `RoleService`) marks wholesale partners.
- **Two balance columns.** `balances.balance_micro_usd` is spendable;
  `balances.withdrawable_micro_usd` is the earned subset that Stripe
  may pay out (`coordinator/store/postgres/schema/ledger.go` DDL and
  `coordinator/store/postgres/withdrawable_migration.go`).

## Mechanism

### HTTP controller ownership

`coordinator/api/billing/` owns billing, pricing, referral, earnings and payout
HTTP operations (`Controller`). `coordinator/api/routes.go` keeps route paths,
authentication and financial-limit middleware. `billingController` in
`coordinator/api/billing_controller.go` supplies a narrow account/pricing store,
the existing read cache and metric sink, and the router's admin authorization
callback. Linked-user identity checks use
`coordinator/api/requestauth/identity.go` (`ResolveAccountID`, `RequirePrivyUser`);
JWT-only admission remains a route middleware decision.

`Dependencies.Service` and `Dependencies.BaseRewards` are getters because
`SetBilling` and `SetBaseRewards` can run after `NewServer` registers routes.
The endpoint and inference paths see the same configured services, including
replacement or clearing. Checkout and payout operations keep using the current
billing service's store; transaction, locking and idempotency rules remain in
the existing financial service and store operations. The public Server
reconciler entrypoints delegate to the same controller dependency binding.

```mermaid
flowchart LR
  R[HTTP route and auth middleware] --> C[api/billing.Controller]
  C --> I[requestauth identity checks]
  C --> B[Current billing service]
  C --> S[Shared account/pricing store]
  B --> L[Existing ledger and payout transactions]
  C --> H[httpresponse JSON and errors]
```

### Inference accounting ownership

`coordinator/inference/settlement/` owns reservation pricing, service-account
holds, refunds, parked billing records and completion accounting (`Service`,
`ServiceHolds`, `Holder`). `inferenceSettlement` in
`coordinator/api/inference_settlement.go` binds the existing ledger and startup
hold map. Store, provider and referral getters resolve the current dependencies;
asynchronous usage and credit writes also resolve the store when they run.
The hold map retains its startup balance reader and enabled setting.

`handleCompleteAt` in `coordinator/api/provider.go` keeps the provider-terminal
claim and lifecycle. After that claim, `Service.Complete` resolves price,
finalizes the reservation and, when that financial path wins, records in-memory
usage while scheduling durable usage. It then calls the API's existing outcome/timing observation block before
looking up the current referral service and waiting for provider/platform credit
operations. The settlement profile stamp follows those operations. Only after
`Complete` returns does the API signal the consumer channels and mark the
provider idle (`coordinator/inference/settlement/completion.go`). The asynchronous
usage insert is not part of that wait.

Grace-expiry outcome, log and metric decisions remain in
`coordinator/api/settlement.go` (`holdForSettlement`). The `Holder.Hold` timer
uses `Holder.Claim` to remove the parked record under its mutex before the expiry
callback runs; reservation
finalization remains guarded by `PendingRequest.FinalizeReservation`.

### Prices

| Concern | How |
|---|---|
| Storage | `model_prices(account_id, model, input_price, output_price)`, primary key `(account_id, model)`. Platform prices use `account_id = 'platform'`; a provider's custom prices use its own account id (`coordinator/store/postgres/schema/billing.go`). |
| Platform price writers | `PUT /v1/admin/pricing` (`coordinator/api/billing/pricing.go` `AdminPricing`) and model registration, which requires positive `input_price`/`output_price` and writes them as the platform row (`coordinator/api/catalog/register_model.go` `RegisterModel` → `SetModelPrice("platform", …)`). |
| Provider custom price | `PUT /v1/pricing` / `DELETE /v1/pricing` for the caller's own account; a resolved linked user is required (`coordinator/api/billing/pricing.go` `SetPricing`, `DeletePricing`). The only validation is `> 0`; there is no floor or ceiling relative to the platform price. |
| Resolution at settlement | provider custom → platform → `DefaultInputPricePerMillion` / `DefaultOutputPricePerMillion` (`coordinator/inference/settlement/completion_price.go` `priceCompletion`). Service consumers skip the first step. The reservation uses the same order with the provider chosen at dispatch (`coordinator/inference/settlement/reservation_price.go` `providerEstimate`, `Estimate`). |
| Cost | `calculateCost` bills `promptTokens × in / 1M + completionTokens × out / 1M`. `CalculateCostWithOverrides` then applies `minimumChargeMicroUSD`; `CalculateCostWithOverridesNoMinimum` (service traffic) floors non-zero usage at 1 µUSD instead (`coordinator/payments/pricing.go`). Cached tokens: invariant 5. |
| Public read | `GET /v1/pricing` returns the `platform` rows plus the fallback defaults (`GetPricing`); the OpenRouter model feed renders µUSD/1M as USD-per-token strings via `coordinator/payments/pricing.go` `FormatPerTokenUSD`. |

### Request lifecycle

```mermaid
sequenceDiagram
  participant C as Consumer
  participant A as API lifecycle
  participant T as settlement.Service
  participant S as Shared ledger and store
  participant P as Provider
  C->>A: Inference request
  A->>A: accounts.CheckKeySpendCap
  A->>T: Reserve / ReserveForProvider
  T->>S: Debit reservation or hold service balance
  A->>P: Dispatch
  P-->>A: inference_complete with usage
  A->>A: Claim provider terminal
  A->>T: Complete
  T->>S: Finalize charge/refund and publish usage
  Note over T,S: Durable usage insert runs asynchronously
  T->>A: Existing outcome/timing observations
  T->>S: Referral distribution and provider/platform credits
  Note over T,S: Wait for both credit operations
  T-->>A: Final cost and payout
  A-->>C: Signal completion channels
  Note over A,T: Abort: Refund; disconnected request: Holder then late terminal or expiry
```

| Step | Function | What happens |
|---|---|---|
| 1. Reserve | `coordinator/api/inference_admission.go` `reserveInferenceBalance` | `reserved = Service.Estimate(model, max(billingPromptTokens, estimatedPromptTokens), requestedMaxTokens)` at the platform price. The output bound follows the precedence in [pricing-model.md → Formulas](../reference/pricing-model.md#formulas) (`coordinator/api/consumer.go` `ensureMaxTokensBound`; an explicit value is never clamped). The per-key spend cap is checked first (`accounts.CheckKeySpendCap`), then `Service.Reserve` (`coordinator/inference/settlement/reservation.go`) debits the ledger (`LedgerCharge`, reference `reserve:<account>`) or, for a service account with holds enabled, adds to an in-memory hold (`coordinator/inference/settlement/service_holds.go` `ServiceHolds`). Self-route and a nil billing backend skip the step entirely. |
| 2. Media top-up | `topUpReservationForInlinedMedia` | After remote media is fetched and inlined, the byte-bound prompt estimate is recomputed; if it exceeds the reservation the delta is reserved with the same cap check and mode. |
| 3. Provider top-up | `coordinator/inference/settlement/reservation_price.go` `ReserveForProvider` | If the chosen provider has a custom price above the platform price, the delta is debited after a second spend-cap check against the new total. `ErrInsufficientBalance` excludes that provider and dispatch tries another; when none fits the request fails with 402 (`coordinator/api/dispatch.go` `dispatchPrimary`, `run`). Service consumers and free self-route skip it. If dispatch to that provider then fails, `RefundProviderExtra` (`coordinator/inference/settlement/refund.go`) credits the delta back (metric `billing.reservation_extra_refunds`). |
| 4. Settle | `coordinator/inference/settlement/completion_price.go` `priceCompletion`; `completion_finalize.go` `finalizeCompletion` | Resolve the price, compute `totalCost`; an owned machine serving its owner's request settles free (`totalCost = 0`). Exactly one of the settlement or refund paths wins the reservation (`registry.PendingRequest.FinalizeReservation` / `MarkReservationFinalized`). Overage: `overage = totalCost − reserved`, clamped so `totalCost ≤ 2 × reserved` (metric `billing.cost_clamped`), then `Debit(overage, "overage:<request_id>")`; if that debit fails `totalCost = reserved`. Underage: `Credit(reserved − totalCost, LedgerRefund, <request_id>)`. Service hold: `Debit(totalCost)` and release the hold; a failed debit zeroes cost and payout (`billing.uncollected_zeroed`). No reservation and not free: `Debit(totalCost)`. |
| 5. Record usage | `coordinator/inference/settlement/completion_usage.go` `recordCompletionUsage` | After financial finalization wins, record in-memory `payments.Ledger.RecordUsage` (bounded recent history, lazily allocated to the [usage history limit](../reference/pricing-model.md#constants)); schedule a persistent `usage` row (`RecordUsageFullWithPublicModel`) unless the request was free self-route. |
| 6. Pay out | `coordinator/inference/settlement/completion_credit.go` `creditCompletion` | `feePercent` is the consumer's `users.platform_fee_percent` override, else the global default (invariant 4). `providerPayout = ProviderPayoutWithPercent(totalCost, feePercent)` and `platformFee = PlatformFeeWithPercent(totalCost, feePercent)` are computed before `DistributeReferralReward` carves the referrer's share out of the fee. `CreditProviderAccount` credits `providerPayout` as withdrawable earnings (only when the provider is linked and the payout is > 0); the remaining fee is credited to `platform` (`LedgerPlatformFee`). |
| 7. Abort / disconnect | `coordinator/inference/settlement/refund.go` `Refund`; `coordinator/inference/settlement/holder.go` `Holder` | A request that fails before any provider terminal refunds the whole reservation (`LedgerRefund`, reference `reservation_refund:<request_id>`). If the consumer disconnects first, the billing record is parked for `settlement.DefaultGrace = 30 * time.Second` so a late terminal settles it; otherwise it is refunded. |

### Ledger

Tables (all `CREATE TABLE IF NOT EXISTS` in `coordinator/store/postgres/schema/`):
`balances`, `ledger_entries(account_id, entry_type, amount_micro_usd,
balance_after, reference, created_at)`, `model_prices`, `billing_sessions`,
`referrers`, `referrals`, `invite_codes`, `invite_redemptions`,
`provider_earnings` (unique partial index `idx_provider_earnings_job` on
`job_id`), `provider_payouts` (legacy), `stripe_withdrawals`,
`provider_floor_draws` (`UNIQUE (provider_key, epoch_id)`), and the
`users.role` / `users.platform_fee_percent` / `users.stripe_*` columns.

Which path writes each `LedgerEntryType` (`coordinator/store/contracts/ledger.go`),
and which balance column moves:

| Entry type | Written by | Column(s) |
|---|---|---|
| `charge` | reservation, overage, and direct debits — `payments.Ledger.Charge` → `store.Debit` | both (withdrawable capped, invariant 8) |
| `refund` | reservation refund, settlement refund, withdrawal refunds (`Service.Refund`, `Service.finalizeCompletion`, `CreditWithdrawableOnce` in `coordinator/api/billing/connect_payout_events.go` and `coordinator/api/billing/connect_transfer_reversal.go`) | `balance` for reservation/settlement refunds; both for withdrawal refunds |
| `payout` | `provider_earnings` credit path (`CreditProviderAccount` ledger CTE) | both |
| `platform_fee` | `Service.creditCompletion` → `store.Credit("platform", …)` | `balance` |
| `referral_reward` | `coordinator/billing/referral.go` `DistributeReferralReward` → `CreditWithdrawable` | both |
| `stripe_deposit` | `StripeWebhook` → `Service.CreditDeposit` → `store.Credit` | `balance` |
| `stripe_payout` | `coordinator/api/billing/connect_withdraw.go` `StripeWithdraw` → `CreateStripeWithdrawalWithDebit` | both (guarded by `withdrawable_micro_usd >= amount`) |
| `invite_credit` | `coordinator/api/accounts/invites.go` `Controller.RedeemInvite` → `store.Credit` | `balance` |
| `admin_credit` | `AdminCredit` → `handleAdminBalanceAdjustment` → `store.Credit` | `balance` |
| `admin_reward` | `AdminReward` → `handleAdminBalanceAdjustment` → `CreditWithdrawable` | both |
| `provider_floor_draw` | `coordinator/store/postgres/base_rewards.go` `SettleProviderFloorDraw` | both |
| `migration` | `coordinator/store/postgres/ledger.go` `MigrateAccountBalance` (balance moved between account identities) | both |
| `deposit`, `withdrawal` | declared for legacy (pre-Stripe) deposit and on-chain withdrawal paths; no current handler writes them | — |

`RewardLedgerTypes = {referral_reward, admin_reward}` is the set the
leaderboard and `GET /v1/me/summary` count as "reward" rather than "work"
earnings (`coordinator/store/contracts/ledger.go` `IsRewardLedgerType`;
`coordinator/api/accountfleet/summary.go` `Controller.Summary`).

Three credit primitives (`coordinator/store/postgres/ledger.go`):

| Primitive | Effect | Used for |
|---|---|---|
| `Credit` (`creditTx`) | raises `balance_micro_usd` only; not reference-idempotent | deposits, invite/admin credits, reservation and settlement refunds, platform fee |
| `CreditWithdrawable` (`creditWithdrawableTx`) | raises both columns; not reference-idempotent | referral rewards, admin rewards |
| `CreditWithdrawableOnce` | `CreditWithdrawable` guarded by a `pg_advisory_xact_lock` on `entry_type:reference` and an existence check on `(account_id, entry_type, reference)`; returns whether it applied | withdrawal principal and fee refunds |

`CreditProviderAccount` and `SettleProviderFloorDraw` are single-statement
CTEs whose first `INSERT … ON CONFLICT DO NOTHING` gates every downstream
credit (invariants 7 and 15).

### Service accounts

`RoleService` is granted by `PUT /v1/admin/users/role` with
`{"role": "service"}` (`""` clears it) (`AdminSetUserRole`,
`SetUserRole`). Effects: cost via `CalculateCostWithOverridesNoMinimum`;
billed at the platform price with no provider-custom-price top-up
(`isServiceConsumer`); when
`EIGENINFERENCE_SERVICE_RESERVATIONS_ENABLED=true` (default `false`,
`coordinator/api/server_config.go` `ReadServerConfig`) reservations are
in-memory holds (`mode:service_hold`) and the actual cost is debited at
settlement; requests use the dedicated service rate limiter
(`Service`; values under [pricing-model constants](../reference/pricing-model.md#constants)).
The platform fee follows the same per-user override as everyone else.

### Deposits (Stripe Checkout)

1. `POST /v1/billing/stripe/create-session` (`StripeCreateSession`;
   auth + financial limiter) requires `amount_usd` at or above the [Stripe deposit minimum](../reference/pricing-model.md#constants), validates an
   optional `referral_code`, creates a Checkout Session whose metadata carries
   `billing_session_id`, `consumer_key`, and `referral_code`
   (`coordinator/billing/stripe.go` `CreateCheckoutSession`), stores a
   `billing_sessions` row with `status = pending`, and returns
   `{session_id, stripe_session, url, amount_usd, amount_micro_usd}`.
2. Stripe calls `POST /v1/billing/stripe/webhook` (`StripeWebhook`; no
   auth, `Stripe-Signature` verified by `VerifyWebhookSignature`). Only
   `checkout.session.completed` is processed; every other event type is
   acknowledged with 200 and ignored.
3. If `metadata.billing_session_id` names a session already `completed`, the
   handler returns 200 without crediting. Otherwise it credits
   `AmountTotal × 10_000` µUSD (`CreditDeposit` → `store.Credit`, entry
   `stripe_deposit`, reference `stripe:<checkout_session_id>`), then marks the
   session complete and applies the referral code — both best-effort (metrics
   `billing.session_complete_failed`, `billing.referral_apply_failed`).
4. `GET /v1/billing/stripe/session?id=<session_id>` polls the row;
   `GET /v1/billing/methods` (public) lists configured methods — Stripe only
   (`coordinator/billing/billing.go` `SupportedMethods`).

Deposits are **not withdrawable** (they use `Credit`). The dedup gap in this
sequence is stated under Failure modes.

### Provider payouts (Stripe Connect Express)

| Stage | Function | Behaviour |
|---|---|---|
| Onboard | `coordinator/api/billing/connect_onboarding.go` `StripeOnboard` (Privy only) | Creates or reuses an Express account (`coordinator/billing/stripe_connect.go` `CreateExpressAccount`) with the service agreement chosen by `coordinator/billing/stripe_regions.go` `RequiredServiceAgreement` (`full` or `recipient`), returns a hosted onboarding link (`CreateAccountLink`). Local status ∈ {`""`, `pending`, `ready`, `restricted`, `rejected`} is mirrored from `account.updated`. |
| Status | `StripeStatus` | Returns `status`, `destination_type`, `destination_last4`, `instant_eligible`, `min_withdraw_micro_usd`, `instant_fee_bps`, `instant_fee_min_usd`; `?refresh=1` re-syncs from Stripe. |
| Withdraw | `coordinator/api/billing/connect_withdraw.go` `StripeWithdraw` (Privy only, status `ready`) | Body `{amount_usd, method: standard \| instant}`. Pre-validates the account with Stripe (gone → unlink + 409 `stripe_account_gone`; agreement mismatch → 409 `stripe_account_recreate_required`; payouts disabled → 403 `not_onboarded`; a `manual` payout schedule is healed to automatic). `gross ≥ MinWithdrawMicroUSD`; `fee = FeeForMethodMicroUSD` (`0` for standard; the instant fee is the [withdrawal-fee formula](../reference/pricing-model.md#formulas) over `InstantFeeBps` / `InstantFeeMinMicroUSD`, values under [Constants](../reference/pricing-model.md#constants)); `net = gross − fee` must round to ≥ 1 cent. One store transaction debits both columns (`stripe_payout`, reference `stripe_withdraw:<id>`) and inserts the `pending` row **before** any Stripe call. Then `transfers.create` for `net` cents with idempotency key `wd-tr-<id>` (`retryAmbiguousStripe`). Definitive failure → refund gross via `creditRefundOnceWithRetry`, row `failed`. Ambiguous (no answer) → row stays `pending`, **no refund**, 502. Success → `transferred`. |
| Deliver | `StripeWithdraw`, Stripe schedule | Standard: nothing more; Stripe's automatic daily payout sweeps the connected balance to the bank in local currency. Instant: `payouts.create` (`wd-po-<id>`) to the debit card; a definitive failure refunds only the instant fee (`stripe_withdraw_fee:<id>`) and the sweep delivers via the standard rail; an ambiguous failure refunds nothing (202). |
| Webhooks | `coordinator/api/billing/connect_webhook.go` `StripeConnectWebhook` (no auth, `VerifyConnectWebhookSignature`) | See the Connect webhook table under Failure modes. |
| Reconcile | `coordinator/api/billing/connect_reconcile.go` `StartStripePayoutReconciler` | Every `stripeReconcileInterval` (first pass 1 min after boot), inspects up to `stripeReconcileBatch` rows, heals `manual` payout schedules, and alerts on rows non-terminal for more than `stripeStuckThreshold` (values under [Constants](../reference/pricing-model.md#constants)). Never touches the ledger. |
| Self-service | `StripeDashboardLink` (`POST /v1/billing/stripe/dashboard`, Privy + financial limiter), `StripeUnlink` (`DELETE /v1/billing/stripe/account`), `StripeWithdrawals` (`GET /v1/billing/stripe/withdrawals`) | Express dashboard login link; unlink; withdrawal history. |

Withdrawal row state machine: `pending → transferred → paid | failed`
(`StripeWithdraw` comment block). There is no coordinator-side payout
schedule or threshold beyond `MinWithdrawMicroUSD`.

### International bank withdrawals

When Global Payouts is enabled, the server returns its explicit country policy in the existing payout status response. New destinations outside the configured Connect transfer region use Stripe-hosted recipient onboarding. Existing ready Connect destinations remain on Connect (`coordinator/api/billing/global_onboarding.go`, `maybeGlobalOnboard`). With the feature disabled, users without a Global Payouts recipient retain the legacy Connect onboarding and country menu, even when Global Payouts credentials are staged. Transient Stripe bank-lookup failures preserve the last verified destination and return a temporary error. The UI presents bank setup and withdrawal without asking users to select payment infrastructure.

`GlobalPayoutQuote` (`coordinator/api/billing/global_quote.go`) verifies recipient and bank eligibility and stores an immutable request plus local-currency estimate without moving earnings. Confirming the quote calls `BeginGlobalPayout` (`coordinator/store/postgres/global_payouts.go`), which locks the payout and recipient, guards both balance columns, and records the debit in one transaction. Connect withdrawals contend on the same balance row.

`syncGlobalPayout` (`coordinator/api/billing/global_reconcile.go`) uses a persistent idempotency key and reconciles current Stripe state after webhook notifications. Leases bound concurrent sends. Ambiguous results retain the debit; repeated confirmations retain the original identity even after unlinking. A definitive rejection of the first send is recorded with `RecordGlobalPayoutRejection` before the refund transaction; subsequent workers apply that saved rejection without another send if the refund write fails. A bank return refunds once in the same transaction as its state change. Known external payments continue to reconcile against their immutable source even when the configured funding account changes. Old unsubmitted quotes are invalidated before debit; a confirmed intent with no previous dispatch is refunded if its funding source changed. Ambiguous attempts retain their debit. After twelve hours without an external ID, `GlobalPayout.RequiresManualReconciliation` excludes the marked payout from automatic scans and claims while retaining its debit and history. The UI labels `posted` as sent, not paid. The [rollout runbook](../operations/global-payouts.md) defines live validation and rollback obligations.

`useStripeWithdrawal` (`console-ui/src/components/payouts/useStripeWithdrawal.ts`) saves the confirmation identity in account-scoped browser storage before sending it. Global Payouts status loading restores that identity before enabling another withdrawal; Connect status and submission do not read this storage. Recovery remains available after remounts, zero remaining balance, or paused admissions. Storage failures stop Global Payouts submission; credentials and full bank details are not stored.

Recipient limits are stored in API minor units and shown before review. USD destination bounds are checked before requesting a quote; foreign-currency bounds are checked against Stripe's credited quote amount and its amount-limit errors. A USD input is never compared directly with a foreign-currency floor (`coordinator/billing/globalpayouts/recipient_limits.go`, `Country.Limits`).

### Consumer referral

`coordinator/billing/referral.go`: `POST /v1/referral/register` creates one
code per account (`validateReferralCode`: 3–20 characters, letters, digits and
hyphens, no leading/trailing hyphen, uppercased). `POST /v1/referral/apply`
links the caller to a referrer once — no self-referral, no second referrer
(`Apply`); a `referral_code` in Checkout metadata applies implicitly after a
deposit. Register and apply require a Privy user and run under the financial
limiter. `GET /v1/referral/stats` and `GET /v1/referral/info` read back.
Reward: `DistributeReferralReward` credits the referrer
`referralSharePercent` (`EIGENINFERENCE_REFERRAL_SHARE_PCT`; default and clamp under
[Constants](../reference/pricing-model.md#constants)) of the **platform fee** of each referred request as
withdrawable `referral_reward`. Because the fee is what invariant 4 says it
is, the reward is zero unless the referred consumer has a per-user fee
override. The provider referral program described in
[`design/provider-referral-growth-program.md`](../design/provider-referral-growth-program.md) is not
implemented: no tables, ledger types, or handlers exist.

### Invite codes and admin credits

Admins create (`POST /v1/admin/invite-codes`: `amount_usd`, optional `code`,
`max_uses` default `1`, `expires_at` RFC 3339), list, and deactivate codes
(`coordinator/api/authorization.go`, `requireAdminKey`). Any authenticated
account redeems with `POST /v1/invite/redeem`; `RedeemInviteCode` locks the
code row and checks active, unexpired, under `max_uses`, then inserts into
`invite_redemptions` whose primary key `(code, account_id)` blocks a second
redemption by the same account; the credit is a non-withdrawable
`invite_credit`. `POST /v1/admin/credit` (`admin_credit`, non-withdrawable)
and `POST /v1/admin/reward` (`admin_reward`, withdrawable) credit by user
email. These, plus free self-route, are the only free-credit paths — there is
no sign-up credit or trial in code. Admin authorization for these routes is
`isAdminAuthorized` / `requireAdminKey`: an `EIGENINFERENCE_ADMIN_KEY` bearer
token or a Privy user whose email is in `EIGENINFERENCE_ADMIN_EMAILS`
(`coordinator/api/admin_auth.go`, `coordinator/api/authorization.go`).

### Per-key spend caps

`POST /v1/keys` and `PATCH /v1/keys/{id}` accept `limit_usd` and
`limit_reset ∈ {none, daily, weekly, monthly}`
(`coordinator/api/accounts/key_inputs.go` `validateKeyLimitInputs`), stored as
`APIKey.LimitMicroUSD` / `LimitReset`. `accounts.CheckKeySpendCap` compares
`KeySpendSince(key, window start) + additional` against the cap before the
platform-price reservation, before a media top-up, and again before a
provider top-up. Spend is the sum of settled `usage.cost_micro_usd` for the
key (`coordinator/store/postgres/keys.go` `KeySpendSince`) — see invariant 11.

### Base rewards (implemented, disabled by default)

`coordinator/payments/baserewards/` pays eligible provider machines a
per-epoch base income on top of organic earnings. It is wired in
`coordinator/cmd/coordinator/accounts.go` (`configureAccounts`) only when `EIGENINFERENCE_BASE_REWARDS=true`
(default `false`, `coordinator/api/server_config.go`); the engine loop is
`Engine.Run`. Per closed `SettlementPeriod = 5 * time.Minute` epoch
(`epoch.go`), for each machine that passes every gate in
`engine.go` `buildCandidates` — attested and trust ≥ minimum; online with the
model loaded; `MemoryPressure < 0.8` and thermal state not `critical`; a
provider key; uptime from `provider_sessions` ≥ `MinUptimeFrac` (`0.90`, open
sessions accrue to `last_seen + defaultGraceSeconds = 90`); hardware model in
the memory catalog (`mdm.ModelMaxMemoryGB` caps self-reported memory
downward; unknown models are skipped); and a linked payout account:

```
avail  = clamp((uptime − 0.90) / 0.10, 0, 1)                          floor.go Avail
floor  = TierFloor(memGB) × period/month × avail                        floor.go PeriodFloor
draw   = max(0, floor − k × organicEarnings),  k = DefaultReductionK = 0.0   floor.go Draw
```

`AllocateDraws` (`alloc.go`) caps the epoch's total at
`PeriodBudget(FloorPoolBudgetMicroUSD)` minus
what earlier runs already settled for the epoch, funds the
`workhorseMinGB`–`workhorseMaxGB` band first from a `WorkhorseReserveFrac` sub-pool, then
water-fills by `valuePerFloorDollar`; `PerAccountCapFrac = 0` disables the
per-account cap. `SettleProviderFloorDraw` writes one
`provider_floor_draws` row per `(provider_key, epoch_id)`, credits the
account as withdrawable `provider_floor_draw`, and mirrors a
`provider_earnings` row with `model = 'base_reward'` and
`job_id = floor:<epoch>:<provider_key>` so it shows in earnings history while
`SumProviderEarningsByKey` excludes it from organic earnings. Settlement is
serialized by an advisory lock. `GET /v1/admin/base-rewards` returns
`{"enabled": false}` when the engine is not wired
(`coordinator/api/billing/base_rewards.go`). The tier table is in
[`reference/pricing-model.md`](../reference/pricing-model.md#base-rewards);
the design record is [`design/base-rewards.md`](../design/base-rewards.md).

## Invariants

1. **Integer money.** All internal amounts are integer µUSD; Stripe amounts
   are integer cents. Sub-cent dust on a withdrawal is absorbed by the gross
   debit and never refunded (`coordinator/api/billing/connect_withdraw.go`
   `StripeWithdraw`; `coordinator/api/billing/amounts.go`
   `microUSDToCents`).
2. **The reservation is the worst case and the cap.** The reservation is
   computed at the platform price for the estimated prompt plus the bounded
   output; settlement charges more only through the overage debit, and never
   more than `2 × reserved` (`coordinator/inference/settlement/completion_finalize.go`
   `finalizeCompletion`; `coordinator/inference/settlement/reservation_price.go`
   `Estimate`; `coordinator/api/consumer.go` `ensureMaxTokensBound`).
3. **Price resolution order** is provider custom → platform → hardcoded
   default, and service consumers never pay a provider custom price
   (`coordinator/inference/settlement/completion_price.go` `priceCompletion`;
   `coordinator/inference/settlement/reservation_price.go` `providerEstimate`,
   `isServiceConsumer`).
4. **The global platform fee is `platformFeePercent = 0`**
   (`coordinator/payments/pricing.go`). `resolveFeePercent` uses a per-user
   `users.platform_fee_percent` override clamped to `[0, 100]` when one is set
   (`PUT /v1/admin/users/platform-fee`, `AdminSetUserPlatformFee`),
   otherwise this constant. `platformFee = totalCost × fee / 100` and
   `providerPayout = totalCost − platformFee` (`PlatformFeeWithPercent`,
   `ProviderPayoutWithPercent`), so at the default every provider receives
   the full `totalCost` and every referral reward is zero.
5. **Cached tokens are free.** `calculateCost` takes only `promptTokens` and
   `completionTokens`; `Usage.CachedTokens` and `PrefillTokensSaved` from the
   provider's terminal message feed only the `routing.cache_*` metrics
   (`coordinator/payments/pricing.go` `calculateCost`;
   `coordinator/api/provider.go` `handleCompleteAt`).
6. **A reservation is settled or refunded at most once.**
   `PendingRequest.FinalizeReservation` / `MarkReservationFinalized` (`coordinator/registry/pending_request.go`) gate every overage debit, settlement
   refund, whole-reservation refund, and service-hold release; a terminal that
   arrives after another path finalized the reservation is logged and skipped
   without writing a usage row (`coordinator/inference/settlement/completion_finalize.go`
   `finalizeCompletion`; `coordinator/inference/settlement/refund.go` `Refund`;
   `coordinator/api/settlement.go` `holdForSettlement`).
7. **Provider earnings are idempotent on `job_id`.** `CreditProviderAccount`
   inserts the `provider_earnings` row under the unique partial index
   `idx_provider_earnings_job` (`job_id <> ''`) in the same transaction as the
   withdrawable credit, so a re-settled job is a no-op instead of a second
   payout (`coordinator/store/postgres/earnings.go`).
8. **`withdrawable_micro_usd ≤ balance_micro_usd`.** `Debit` lowers
   withdrawable to `LEAST(withdrawable, balance − amount)`; `Credit` raises
   only `balance`; `CreditWithdrawable`, `CreditWithdrawableOnce`, and
   `CreditProviderAccount` raise both by the same amount;
   `CreateStripeWithdrawalWithDebit` debits both and fails unless
   `withdrawable ≥ amount` (`coordinator/store/postgres/ledger.go`, `coordinator/store/postgres/stripe_withdrawals.go`).
9. **Only earned money is withdrawable.** `stripe_deposit`, `invite_credit`,
   `admin_credit`, and reservation or settlement `refund` entries go through
   `Credit`; `payout`, `referral_reward`, `admin_reward`,
   `provider_floor_draw`, and withdrawal refunds go through the withdrawable
   primitives (`coordinator/api/billing/checkout_webhook.go` `StripeWebhook`;
   `coordinator/api/billing/admin_adjustment.go` `AdminCredit`, `AdminReward`; `coordinator/api/accounts/invites.go`
   `Controller.RedeemInvite`; `coordinator/billing/referral.go`
   `DistributeReferralReward`; `coordinator/store/postgres/base_rewards.go`
   `SettleProviderFloorDraw`).
10. **Withdrawal refunds are reference-idempotent.** Principal
    (`stripe_withdraw:<id>`) and instant-fee (`stripe_withdraw_fee:<id>`)
    refunds use `CreditWithdrawableOnce`, keyed on
    `(account_id, entry_type, reference)` under `pg_advisory_xact_lock`, so a
    redelivered webhook or a reconciler pass cannot refund twice
    (`coordinator/api/billing/connect_retry.go` `creditRefundOnceWithRetry`;
    `coordinator/api/billing/connect_payout_events.go` `handlePayoutTerminal`;
    `coordinator/api/billing/connect_transfer_reversal.go` `handleTransferFailed`; `coordinator/store/postgres/ledger.go`
    `CreditWithdrawableOnce`).
11. **A capped key never debits.** `accounts.CheckKeySpendCap` runs before the `Debit`
    in `reserveInferenceBalance` and `topUpReservationForInlinedMedia`;
    `Service.ReserveForProvider` performs the same cap comparison before its
    top-up. A rejected reservation or top-up writes no new debit row. The cap is soft (settled usage, so concurrent requests can overshoot
    by their reservations); the ledger balance is the hard ceiling
    (`coordinator/api/accounts/key_policy.go`; `coordinator/api/inference_admission.go`;
    `coordinator/inference/settlement/reservation_price.go`).
12. **Service accounts pay the platform price with no minimum.**
    `isServiceConsumer` selects `CalculateCostWithOverridesNoMinimum`, skips
    the provider's `GetModelPrice` row and the `ReserveForProvider` top-up, and
    a service hold whose settlement debit fails zeros both `totalCost` and
    `providerPayout` (`billing.uncollected_zeroed`) rather than paying a
    provider from uncollected money (`coordinator/inference/settlement/completion_price.go`
    `priceCompletion`; `coordinator/inference/settlement/completion_finalize.go`
    `finalizeCompletion`; `coordinator/inference/settlement/reservation.go`).
13. **Self-route is free only when the owner's machine served it.**
    `priceCompletion` sets `totalCost = providerPayout = 0` for `FreeSelfRoute`
    or `PreferOwner` when the serving provider's nonempty `AccountID` equals
    the consumer key; a `FreeSelfRoute` request
    served by another provider settles as paid, and if that charge fails
    nothing is paid out (`coordinator/inference/settlement/completion_price.go`;
    `coordinator/inference/settlement/completion_finalize.go`).
14. **Referral rewards come out of the platform fee.**
    `DistributeReferralReward` credits the referrer
    `platformFee × share / 100` and returns the remainder for the `platform`
    account; `providerPayout` is unchanged (`coordinator/billing/referral.go`).
15. **Base-reward draws are idempotent and never count as organic earnings.**
    `SettleProviderFloorDraw` inserts into `provider_floor_draws`
    (`UNIQUE (provider_key, epoch_id)`), credits withdrawable, and mirrors a
    `provider_earnings` row with `model = 'base_reward'` that
    `SumProviderEarningsByKey` excludes from the next epoch's `earned`
    (`coordinator/store/postgres/base_rewards.go`).

## Failure modes

### Payment-required responses

Bodies are `{"error": {"type", "message", "code"}}` (`coordinator/api/httputil.go`
`errorResponse`); `code` is `insufficient_quota` for every 402 below except
the last row.

| Condition | HTTP | `error.type` | `error.code` | Where |
|---|---|---|---|---|
| Per-key spend cap would be exceeded by the platform-price reservation | 402 | `insufficient_quota` | `insufficient_quota` | `reserveInferenceBalance` |
| Ledger balance below the reservation (`ErrInsufficientBalance`) | 402 | `insufficient_funds` | `insufficient_quota` | `reserveInferenceBalance` |
| Media top-up exceeds the spend cap | 402 | `insufficient_quota` | `insufficient_quota` | `topUpReservationForInlinedMedia` |
| Media top-up exceeds the balance | 402 | `insufficient_funds` | `insufficient_quota` | `topUpReservationForInlinedMedia` |
| Provider custom-price top-up fails and no other provider fits | 402 | `provider_error` | `provider_error` | message ends `insufficient funds for provider price`; `coordinator/api/dispatch.go` `dispatchPrimary`, `run` |

There is no minimum-balance requirement beyond the reservation; a zero
balance still serves free self-route.

### Other billing errors

| Condition | HTTP | `error.type` | Where |
|---|---|---|---|
| Deposit below the [Stripe deposit minimum](../reference/pricing-model.md#constants) | 400 | `invalid_request_error` | `StripeCreateSession` |
| Unknown `referral_code` on deposit | 400 | `invalid_request_error` | `StripeCreateSession` |
| Withdrawal below [`MinWithdrawMicroUSD`](../reference/pricing-model.md#constants), non-positive, or net < 1 cent | 400 | `invalid_request_error` | `StripeWithdraw` |
| Withdrawal exceeds `withdrawable_micro_usd` | 400 | `insufficient_withdrawable` | `StripeWithdraw` |
| Instant requested without a debit-card destination | 400 | `instant_unavailable` | `StripeWithdraw` |
| Not onboarded / payouts disabled | 403 | `not_onboarded` | `StripeWithdraw` |
| Stripe account deleted | 409 | `stripe_account_gone` | `StripeWithdraw`, `StripeDashboardLink` |
| Service agreement cannot receive transfers | 409 | `stripe_account_recreate_required` | `StripeWithdraw` |
| Transfer or instant payout outcome unconfirmed | 502 / 202 | `stripe_error` / status `transferred` | `StripeWithdraw` — on hold, nothing refunded |
| Stripe / Connect / referral not configured | 503 | `billing_error` | `StripeCreateSession`, `StripeWithdraw`, `ReferralRegister` |
| Admin route without admin credentials | 403 | `forbidden` | `isAdminAuthorized`, `requireAdminKey` |
| Endpoint requires a linked user but the request context has none | 401 | `auth_error` | `RequirePrivyUser` (`coordinator/api/requestauth/identity.go`) |
| Privy-only route called with an API key | 403 | `forbidden` | `requirePrivyAuth` (`coordinator/api/authentication.go`) |

### Stripe Checkout webhook: deposit dedup gap

`StripeWebhook` checks `billing_sessions.status == "completed"`
**before** crediting and marks the session complete **after** crediting, and
`store.Credit` is not reference-idempotent. A redelivered
`checkout.session.completed` that arrives between the credit and the mark, or
after a failed `CompleteBillingSession`, credits the deposit twice. A session
without `billing_session_id` metadata has no dedup at all. `IsExternalIDProcessed`
(`coordinator/billing/billing.go`; `coordinator/store/postgres/billing_sessions.go`) exists
but is not called by the webhook.

### Stripe Connect webhook semantics

`StripeConnectWebhook` acks malformed payloads and business no-ops with
`200` so Stripe stops retrying, and returns non-2xx only when a retry can
help (`coordinator/api/billing/connect_webhook.go`).

| Event | Handling |
|---|---|
| `account.updated` | `handleAccountUpdated` mirrors Stripe's view into `users.stripe_*` (`stripeStatusForAccount`: `pending`, `ready`, `restricted`, or `rejected`). Best-effort; the status endpoint re-syncs on page load. |
| `payout.paid` | `handlePayoutTerminal(success=true)`: matched by payout id → `MarkStripeWithdrawalPaid` (no-op on an already `paid` row; a refunded/terminal row is logged for manual review, never overwritten). Unmatched → `reconcileUnmatchedPayout`: only automatic sweep payouts reconcile; they mark every `transferred` row of that connected account whose funds had become available (`stripeRecipientTransferDelay = 24 * time.Hour` for `recipient` accounts, immediate for `full`) and that has no in-flight payout of its own as `paid`. Amounts are ignored (FX-converted). |
| `payout.failed`, `payout.canceled` | `handlePayoutTerminal(success=false)`: refund the instant fee via `CreditWithdrawableOnce(stripe_withdraw_fee:<id>)`, detach the payout id, reopen the row as `transferred` so the sweep retries. A refunded+paid row is logged for manual review. |
| `transfer.reversed` | `handleTransferFailed`: refund the net principal (`stripe_withdraw:<id>`) and the fee (`stripe_withdraw_fee:<id>`) once each via `CreditWithdrawableOnce`, mark the row `failed`. |
| anything else | acknowledged, ignored |

### Settlement anomalies

| Situation | Behaviour | Signal |
|---|---|---|
| Settled cost above the reservation | Overage debited as `charge` `overage:<request_id>`, clamped to `reserved` (a provider can never bill more than `2 × reserved`); a failed overage debit settles at `totalCost = reserved` | `billing.cost_clamped`, `billing.overage_charged`, `billing.overage_micro_usd` |
| Completion reports zero completion tokens | Direct consumers still settle at `minimumChargeMicroUSD`; service accounts settle at `0`; the warning text "billed $0" is accurate only for the latter | `billing.zero_usage_complete` |
| Consumer disconnects after the first streamed chunk | `holdForSettlement` parks the billing record for `settlement.DefaultGrace = 30 * time.Second`; a provider terminal inside the grace settles the delivered tokens, otherwise `Service.Refund("no_terminal_after_cancel:<id>")` | `routing.client_gone` |
| Provider error, timeout, or dispatch failure before a terminal | `Service.Refund` refunds the whole reservation (`reservation_refund:<id>`) or releases the service hold | `billing.reservation_refunds`, `billing.reservation_releases` |
| Failover after a provider-price top-up | `Service.RefundProviderExtra` refunds only the surcharge (`reservation_extra_refund:<id>`) and resets `ReservedMicroUSD` to the base so it cannot refund twice | `billing.reservation_extra_refunds` |
| Late terminal after finalization | Skipped: no debit, refund, payout, or usage row | log `skipping completion billing for already-finalized reservation` |
| Provider, platform, or refund credit fails | Logged and counted; there is no retry queue, so the provider payout or platform fee for that job is lost | `billing.credit_failed{op}` |

### Datadog billing metrics

Names are written without the Datadog namespace prefix, which is owned by [telemetry-inventory](../reference/telemetry-inventory.md#coordinator-derived-datadog-metrics).

| Metric | Kind | Tags | Emitter |
|---|---|---|---|
| `billing.reservations` | incr | `model`, `mode:ledger\|service_hold`, `outcome:reserved\|rejected` | `coordinator/inference/settlement/reservation.go` (`Reserve`) |
| `billing.reserved_micro_usd` | histogram | `model`, `mode` | `coordinator/inference/settlement/reservation.go` (`Reserve`); `coordinator/inference/settlement/reservation_price.go` (`ReserveForProvider`) |
| `billing.media_reservation_topup` | incr | `model`, `outcome:rejected` | `coordinator/api/inference_admission.go` `topUpReservationForInlinedMedia` |
| `billing.reservation_refunds` | incr | `model`, `mode` | `coordinator/inference/settlement/refund.go` (`Refund`); `coordinator/inference/settlement/reservation.go` (`Release`) |
| `billing.reservation_releases` | incr | `model`, `mode`, `reason:refund\|early\|finalize` | `coordinator/inference/settlement/refund.go` (`Refund`); `coordinator/inference/settlement/reservation.go` (`Release`, `releaseServiceReservation`) |
| `billing.reservation_extra_refunds` | incr | `model` | `coordinator/inference/settlement/refund.go` (`RefundProviderExtra`) |
| `billing.reservation_finalize` | incr | `model`, `mode:service_hold`, `outcome:charged` | `coordinator/inference/settlement/completion_finalize.go` (`finalizeCompletion`) |
| `billing.service_settlement_micro_usd` | histogram | `model` | `coordinator/inference/settlement/completion_finalize.go` (`finalizeCompletion`) |
| `billing.uncollected_zeroed` | incr | `model`, optional `mode:service_hold` | `coordinator/inference/settlement/completion_finalize.go` (`finalizeCompletion`) |
| `billing.cost_clamped` | incr | `model` | `coordinator/inference/settlement/completion_finalize.go` (`finalizeCompletion`) |
| `billing.overage_charged` | incr | `model` | `coordinator/inference/settlement/completion_finalize.go` (`finalizeCompletion`) |
| `billing.overage_micro_usd` | histogram | `model` | `coordinator/inference/settlement/completion_finalize.go` (`finalizeCompletion`) |
| `billing.settlement_refund_micro_usd` | histogram | `model` | `coordinator/inference/settlement/completion_finalize.go` (`finalizeCompletion`) |
| `billing.zero_usage_complete` | incr | `model` | `coordinator/api/provider.go` (`handleCompleteAt`) |
| `billing.provider_credits_micro_usd` | count | `model`, `type:account` | `coordinator/inference/settlement/completion_credit.go` (`creditCompletion`) |
| `billing.platform_fees_micro_usd` | count | `model` | `coordinator/inference/settlement/completion_credit.go` (`creditCompletion`) |
| `billing.credit_failed` | incr | `op:settlement_refund\|platform_fee` | `coordinator/inference/settlement/completion_finalize.go`; `coordinator/inference/settlement/completion_credit.go` |
| `billing.session_complete_failed` | incr | — | `coordinator/api/billing/checkout_webhook.go` `StripeWebhook` |
| `billing.referral_apply_failed` | incr | — | `StripeWebhook` |
| `store.debit.latency_ms`, `store.credit.latency_ms` | histogram | `op:reserve\|charge\|service_reservation_settle\|settlement_refund\|reservation_refund\|provider_account_credit\|platform_fee` | `coordinator/inference/settlement/reservation.go`; `coordinator/inference/settlement/refund.go`; `coordinator/inference/settlement/completion_finalize.go`; `coordinator/inference/settlement/completion_credit.go` |

## Code map

| Concern | Files and symbols | Routes |
|---|---|---|
| HTTP ownership | `coordinator/api/billing/controller.go` (`Controller`, `Dependencies`); `coordinator/api/billing/store.go` (`Store`); `coordinator/api/billing_controller.go` (`billingController`); `coordinator/api/requestauth/identity.go` (`ResolveAccountID`, `RequirePrivyUser`) | Router and middleware remain in `coordinator/api/routes.go` (`routes`). |
| Prices and cost | `coordinator/payments/pricing.go` (`DefaultInputPricePerMillion`, `DefaultOutputPricePerMillion`, `minimumChargeMicroUSD`, `platformFeePercent`, `calculateCost`, `CalculateCostWithOverrides`, `CalculateCostWithOverridesNoMinimum`, `resolveFeePercent`, `PlatformFeeWithPercent`, `ProviderPayoutWithPercent`, `FormatPerTokenUSD`); `coordinator/store/postgres/model_prices.go` (`model_prices`, `GetModelPrice`) | `GET /v1/pricing`, `PUT /v1/pricing`, `DELETE /v1/pricing`, `PUT /v1/admin/pricing`, `POST /v1/admin/models/register` |
| Reservation | `coordinator/inference/settlement/reservation.go` (`Reserve`, `Release`); `coordinator/inference/settlement/reservation_price.go` (`Estimate`, `ReserveForProvider`); `coordinator/inference/settlement/service_holds.go` (`ServiceHolds`); HTTP bounds/cap checks remain in `coordinator/api/inference_admission.go` and `coordinator/api/consumer.go` | — |
| Settlement | `coordinator/inference/settlement/completion.go` (`Service.Complete`); `completion_price.go`, `completion_finalize.go`, `completion_usage.go`, `completion_credit.go`; `coordinator/inference/settlement/refund.go` (`Refund`, `RefundProviderExtra`); `coordinator/inference/settlement/holder.go` (`Holder`, `DefaultGrace`); lifecycle adapters in `coordinator/api/provider.go` (`handleCompleteAt`) and `coordinator/api/settlement.go` (`holdForSettlement`) | `GET /v1/payments/balance`, `GET /v1/payments/usage` |
| Ledger and balances | `coordinator/store/contracts/ledger.go` (`LedgerEntryType`, `RewardLedgerTypes`); `coordinator/store/postgres/ledger.go` (`creditTx`, `creditWithdrawableTx`, `CreditWithdrawableOnce`, `Debit`); `coordinator/store/postgres/earnings.go` (`CreditProviderAccount`); `coordinator/store/postgres/earnings_index.go` (`ensureProviderEarningsJobIndex`) | `GET /v1/provider/earnings`, `GET /v1/provider/account-earnings`, `GET /v1/me/summary` |
| Deposits | `coordinator/billing/stripe.go` (`CreateCheckoutSession`, `VerifyWebhookSignature`, `ParseCheckoutSession`); `coordinator/billing/billing.go` (`CreditDeposit`, `IsExternalIDProcessed`); `coordinator/api/billing/checkout.go` (`StripeCreateSession`, `StripeSessionStatus`); `coordinator/api/billing/checkout_webhook.go` (`StripeWebhook`); `coordinator/api/billing/wallet.go` (`WalletBalance`); `coordinator/api/billing/methods.go` (`BillingMethods`) | `POST /v1/billing/stripe/create-session`, `POST /v1/billing/stripe/webhook`, `GET /v1/billing/stripe/session`, `GET /v1/billing/wallet/balance`, `GET /v1/billing/methods` |
| Stripe response projection | `coordinator/billing/stripe_connect.go` (`parsePayout`, `parseAccount`) | Payout creation and reconciliation share the same decoded fields and parse errors. Account responses select the first currency-default destination, falling back to the first destination. |
| Payouts | `coordinator/billing/stripe_connect.go` (`MinWithdrawMicroUSD`, `InstantFeeBps`, `InstantFeeMinMicroUSD`, `FeeForMethodMicroUSD`); `coordinator/billing/stripe_regions.go` (`RequiredServiceAgreement`); `coordinator/api/billing/connect_onboarding.go` (`StripeOnboard`); `coordinator/api/billing/connect_status.go` (`StripeStatus`); `coordinator/api/billing/withdrawal_history.go` (`StripeWithdrawals`); `coordinator/api/billing/connect_dashboard.go` (`StripeDashboardLink`, `StripeUnlink`); `coordinator/api/billing/amounts.go` (`microUSDToCents`); `coordinator/api/billing/connect_withdraw.go` (`StripeWithdraw`); `coordinator/api/billing/connect_retry.go` (`creditRefundOnceWithRetry`); `coordinator/api/billing/connect_webhook.go` (`StripeConnectWebhook`); `coordinator/api/billing/connect_sweep.go` (`stripeRecipientTransferDelay`); `coordinator/api/billing/connect_reconcile.go` (`StartStripePayoutReconciler`); `coordinator/store/postgres/stripe_withdrawals.go` (`CreateStripeWithdrawalWithDebit`) | `POST /v1/billing/stripe/onboard`, `GET /v1/billing/stripe/status`, `POST /v1/billing/withdraw/stripe`, `GET /v1/billing/stripe/withdrawals`, `POST /v1/billing/stripe/dashboard`, `DELETE /v1/billing/stripe/account`, `POST /v1/billing/stripe/connect/webhook` |
| Global Payouts | `coordinator/api/billing/global_onboarding.go` (`maybeGlobalOnboard`); `coordinator/api/billing/global_quote.go` (`GlobalPayoutQuote`); `coordinator/api/billing/global_withdraw.go` (`maybeGlobalWithdraw`); `coordinator/api/billing/global_reconcile.go` (`syncGlobalPayout`, `StartGlobalPayoutReconciler`); `coordinator/api/billing/global_webhook.go` (`GlobalPayoutWebhook`); `coordinator/api/billing/global_persistence.go` (`recordGlobalPayoutRejection`) | Existing onboarding, quote, confirmation, status, history and signed webhook routes. |
| Referral | `coordinator/api/billing/referrals.go` (`ReferralRegister`, `ReferralApply`, `ReferralStats`, `ReferralInfo`); `coordinator/billing/referral.go` (`ReferralService`, `Register`, `Apply`, `DistributeReferralReward`, `validateReferralCode`); `coordinator/billing/config.go` (`ReferralSharePercent`) | `POST /v1/referral/register`, `POST /v1/referral/apply`, `GET /v1/referral/stats`, `GET /v1/referral/info` |
| Invite codes and admin credits | `coordinator/api/accounts/invites.go`, `coordinator/api/authorization.go` (`Controller.CreateInvite`, `Controller.ListInvites`, `Controller.DeactivateInvite`, `Controller.RedeemInvite`, `requireAdminKey`); `coordinator/store/postgres/invites.go` (`RedeemInviteCode`); `coordinator/api/billing/admin_adjustment.go` (`AdminCredit`, `AdminReward`) | `POST /v1/admin/invite-codes`, `GET /v1/admin/invite-codes`, `DELETE /v1/admin/invite-codes`, `POST /v1/invite/redeem`, `POST /v1/admin/credit`, `POST /v1/admin/reward` |
| Roles and fee overrides | `coordinator/api/billing/account_policy.go` (`AdminSetUserRole`, `AdminSetUserPlatformFee`); `coordinator/store/postgres/users.go` (`SetUserRole`, `SetUserPlatformFeePercent`) | `PUT /v1/admin/users/role`, `PUT /v1/admin/users/platform-fee` |
| Per-key spend caps | `coordinator/api/accounts/key_projection.go`, `coordinator/api/accounts/key_inputs.go`, `coordinator/api/accounts/key_policy.go` (`validateKeyLimitInputs`, `accounts.CheckKeySpendCap`, `apiKeyToResponse`); `coordinator/store/contracts/keys.go` (`KeySpendWindowStart`, `NormalizeResetWindow`); `coordinator/store/postgres/keys.go` (`KeySpendSince`) | `POST /v1/keys`, `PATCH /v1/keys/{id}`, `GET /v1/keys` |
| Base rewards | `coordinator/payments/baserewards/` (`floor.go`, `alloc.go`, `epoch.go`, `engine.go`); `coordinator/store/postgres/base_rewards.go` (`SettleProviderFloorDraw`, `SumProviderEarningsByKey`); `coordinator/api/billing/base_rewards.go` (`AdminBaseRewards`); `coordinator/api/server_config.go` (`BaseRewards`) | `GET /v1/admin/base-rewards` |
| Admin auth | `coordinator/api/admin_auth.go` (`isAdminAuthorized`); `coordinator/api/authorization.go` (`requireAdminKey`); `coordinator/api/catalog/publishing_auth.go` (`requirePublishingAPIKey`) | — |
| Rate limits | `coordinator/ratelimit/config.go` (`Financial`, `Service`) | — |

## Related

- [`reference/pricing-model.md`](../reference/pricing-model.md) — every constant, formula, enum value, route, and environment variable in table form
- [`consumer/billing.md`](../consumer/billing.md) — how-to for API consumers: deposit, balance, 402s, spend caps
- [`provider/self-route.md`](../provider/self-route.md) — free settlement when your own machine serves the request
- [`design/base-rewards.md`](../design/base-rewards.md) — the base-rewards design record (status: implemented, disabled by default)
- [`architecture/request-outcome-observability.md`](request-outcome-observability.md) — how billing outcomes join the request outcome taxonomy
- [`reference/api-contracts.md`](../reference/api-contracts.md) — error envelope and status codes
- [`storage.md`](storage.md) — which store backend holds the ledger and what survives a restart
