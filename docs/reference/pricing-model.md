# Pricing model reference

> Last updated: 2026-09-05 · commit `4d9811f7c`

Constants, formulas, enums, routes, and environment variables of the
coordinator's money path, each row cited to the code that defines it. How the
pieces fit together, and what they guarantee, is explained in
[`architecture/billing.md`](../architecture/billing.md); the consumer how-to is
[`consumer/billing.md`](../consumer/billing.md).

## Units

| Quantity | Unit | Citation |
|---|---|---|
| Balances, reservations, ledger amounts, earnings | `int64` micro-USD; 1 USD = 1,000,000 µUSD | `coordinator/payments/payments.go` (package comment) |
| Prices (`input_price`, `output_price`) | µUSD per 1,000,000 tokens | `coordinator/payments/pricing.go` (`DefaultInputPricePerMillion`) |
| Stripe Checkout amount in | `AmountTotal` cents × `10_000` = µUSD | `coordinator/api/billing_handlers.go` (`handleStripeWebhook`) |
| Stripe Connect amount out | `microUSDToCents(µUSD)` integer cents; sub-cent remainder stays with the platform | `coordinator/api/stripe_payouts.go` (`microUSDToCents`); `coordinator/api/stripe_withdraw.go` (`handleStripeWithdraw`) |
| OpenRouter model feed | USD per single token = µUSD/1M ÷ 1e12, rendered as a trimmed decimal string (`50000` → `"0.00000005"`) | `coordinator/payments/pricing.go` (`FormatPerTokenUSD`) |
| `GET /v1/pricing` `*_usd` fields | `"$%.4f"` of µUSD/1M ÷ 1e6 (USD per 1M tokens) | `coordinator/api/billing_handlers.go` (`handleGetPricing`) |

## Constants

| Constant | Value | Meaning | Citation |
|---|---|---|---|
| `usageHistoryLimit` | `100` | Newest in-process usage entries per consumer, oldest first; capacity grows lazily to the limit. Does not prune durable usage or change balances. | `coordinator/payments/payments.go` (`Ledger.RecordUsage`) |
| `DefaultInputPricePerMillion` | `50_000` | fallback input price ($0.05 / 1M tokens) | `coordinator/payments/pricing.go` |
| `DefaultOutputPricePerMillion` | `200_000` | fallback output price ($0.20 / 1M tokens) | `coordinator/payments/pricing.go` |
| `minimumChargeMicroUSD` | `100` | per-request floor ($0.0001) applied by `CalculateCostWithOverrides`; not applied to service accounts | `coordinator/payments/pricing.go` |
| `platformFeePercent` | see [billing.md, invariant 4](../architecture/billing.md#invariants) | global platform fee when no per-user override is set | `coordinator/payments/pricing.go` |
| `defaultMaxOutputTokens` | `8192` | output bound when the request sets no max-tokens field and the registry has no `max_output_length` | `coordinator/api/consumer.go` |
| `defaultTerminalSettleGrace` | `30 * time.Second` | how long a consumer-disconnected request waits for the provider terminal before refund | `coordinator/api/settlement.go` |
| `MinWithdrawMicroUSD` | `1_000_000` | minimum withdrawal ($1.00) | `coordinator/billing/stripe_connect.go` |
| `InstantFeeBps` | `150` | instant payout fee (1.5%) | `coordinator/billing/stripe_connect.go` |
| `InstantFeeMinMicroUSD` | `500_000` | instant payout fee floor ($0.50) | `coordinator/billing/stripe_connect.go` |
| standard payout fee | `0` | `FeeForMethodMicroUSD("standard", …)` | `coordinator/billing/stripe_connect.go` |
| `stripeRecipientTransferDelay` | `24 * time.Hour` | availability delay of a transfer into a `recipient`-agreement account; sweep-matching cutoff | `coordinator/api/stripe_payouts_webhooks.go` |
| `stripeReconcileInterval` / `stripeStuckThreshold` / `stripeReconcileBatch` | `1 * time.Hour` / `48 * time.Hour` / `200` | payout reconciler cadence, stuck threshold, rows per pass | `coordinator/api/stripe_reconcile.go` |
| Stripe deposit minimum | `0.50` USD | `amount_usd` lower bound on `create-session` | `coordinator/api/billing_handlers.go` (`handleStripeCreateSession`) |
| `ReferralSharePercent` default | `20`; `NewReferralService` resets values outside `(0, 50]` to `20` | referrer's share of the platform fee | `coordinator/billing/config.go` (`ReadConfig`); `coordinator/billing/referral.go` (`NewReferralService`) |
| Referral code | 3–20 characters, letters/digits/hyphen, no leading or trailing hyphen, uppercased | `validateReferralCode` | `coordinator/billing/referral.go` |
| Invite code default `max_uses` | `1`; auto-generated code `INV-<8 hex>` | `handleAdminCreateInviteCode` | `coordinator/api/invite_handlers.go` |
| Financial rate limiter | `0.2` rps, burst `3` | `create-session`, `POST/PATCH/DELETE /v1/keys`, referral register/apply, invite create/redeem, Stripe dashboard link | `coordinator/ratelimit/config.go` (`Financial`) |
| Service rate limiter | `200` rps, burst `600` | `RoleService` accounts | `coordinator/ratelimit/config.go` (`Service`) |
| `FloorPoolBudgetMicroUSD` | `9_000_000_000` | base-rewards monthly pool ($9,000), prorated per epoch by `PeriodBudget` | `coordinator/payments/baserewards/alloc.go`, `epoch.go` |

## Price resolution

| Order | Source | Lookup | Applies to |
|---|---|---|---|
| 1 | provider custom price | `GetModelPrice(provider.AccountID, model)` | non-service consumers only |
| 2 | platform price | `GetModelPrice("platform", model)` | everyone |
| 3 | hardcoded defaults | `DefaultInputPricePerMillion`, `DefaultOutputPricePerMillion` | everyone |

Settlement: `coordinator/api/provider.go` (`handleCompleteAt`). Reservation:
`coordinator/api/consumer.go` (`reservationCost` uses steps 2–3;
`providerReservationCost` uses 1–3 for the dispatched provider).

| Price writer | Route | Validation | Citation |
|---|---|---|---|
| platform | `PUT /v1/admin/pricing` | `input_price > 0`, `output_price > 0` | `coordinator/api/billing_handlers.go` (`handleAdminPricing`) |
| platform | `POST /v1/admin/models/register` | `input_price`, `output_price` required and positive | `coordinator/api/model_registry_handlers.go` (`handleRegisterModel`) |
| provider custom | `PUT /v1/pricing`, `DELETE /v1/pricing` | positive; no floor or ceiling relative to the platform price | `coordinator/api/billing_handlers.go` (`handleSetPricing`, `handleDeletePricing`) |

Storage: `model_prices(account_id, model, input_price, output_price,
updated_at)`, primary key `(account_id, model)`
(`coordinator/store/postgres.go`).

## Formulas

| Quantity | Formula | Citation |
|---|---|---|
| Raw cost | `promptTokens × inPrice / 1_000_000 + completionTokens × outPrice / 1_000_000`, integer arithmetic | `coordinator/payments/pricing.go` (`calculateCost`) |
| Cost, direct consumers | `max(rawCost, minimumChargeMicroUSD)` | `CalculateCostWithOverrides` |
| Cost, service accounts | `rawCost`; `1` when the tokens are non-zero but the product rounds to `0` (no per-request minimum) | `CalculateCostWithOverridesNoMinimum` |
| Cached tokens | see [billing.md, invariant 5](../architecture/billing.md#invariants) | `calculateCost` |
| Output bound | explicit `max_tokens` \| `max_completion_tokens` \| `max_output_tokens`, else registry `max_output_length`, else `defaultMaxOutputTokens` | `coordinator/api/consumer.go` (`explicitMaxTokens`, `ensureMaxTokensBound`) |
| Reservation | `CalculateCostWithOverrides(model, max(billingPromptTokens, estimatedPromptTokens), outputBound, platform price)` | `coordinator/api/inference_admission.go` (`reserveInferenceBalance`); `coordinator/api/consumer.go` (`reservationCost`) |
| Provider top-up | `providerReservationCost − reserved` when the dispatched provider's custom price makes it positive; skipped for service consumers | `coordinator/api/consumer.go` (`reserveAdditionalForProvider`) |
| Media top-up | `reservationCost(inlined body) − reserved` when positive | `coordinator/api/inference_admission.go` (`topUpReservationForInlinedMedia`) |
| Overage | `min(totalCost − reserved, reserved)`; debited as `charge` with reference `overage:<request_id>`; on failure `totalCost = reserved` | `coordinator/api/provider.go` (`handleCompleteAt`) |
| Settlement refund | `reserved − totalCost` when positive; `refund` entry referenced by `<request_id>` | `handleCompleteAt` |
| Whole-reservation refund | `reserved`; `refund` entry `reservation_refund:<request_id>` | `coordinator/api/consumer.go` (`refundReservedBalance`) |
| Platform fee | `totalCost × resolveFeePercent(user.PlatformFeePercent) / 100`; override clamped to `[0, 100]`, else `platformFeePercent` | `coordinator/payments/pricing.go` (`PlatformFeeWithPercent`, `resolveFeePercent`) |
| Referral reward | `platformFee × ReferralSharePercent / 100`, carved out of the platform fee | `coordinator/billing/referral.go` (`DistributeReferralReward`) |
| Provider payout | `totalCost − platformFee` | `coordinator/payments/pricing.go` (`ProviderPayoutWithPercent`) |
| Withdrawal fee | `0` (standard); `max(gross × InstantFeeBps / 10_000, InstantFeeMinMicroUSD)` (instant) | `coordinator/billing/stripe_connect.go` (`FeeForMethodMicroUSD`) |
| Withdrawal net | `gross − fee`, transferred as `microUSDToCents(net)`; must be ≥ 1 cent | `coordinator/api/stripe_withdraw.go` (`handleStripeWithdraw`) |
| Key spend | `Σ usage.cost_micro_usd` for the key since `KeySpendWindowStart(limit_reset, now)`; request rejected when `spend + additional > LimitMicroUSD` | `coordinator/store/postgres.go` (`KeySpendSince`); `coordinator/api/apikey_handlers.go` (`checkKeySpendCap`) |

## Ledger entry types

`LedgerEntryType` (`coordinator/store/interface.go`). "Withdrawable" says
whether the credit raises `withdrawable_micro_usd`; which function writes each
type is in [billing.md](../architecture/billing.md#ledger).

| Value | Go constant | Meaning | Withdrawable |
|---|---|---|---|
| `deposit` | `LedgerDeposit` | legacy consumer deposit; no current writer | — |
| `charge` | `LedgerCharge` | consumer debit: reservation, overage, or direct charge | debit |
| `payout` | `LedgerPayout` | provider credited for serving a job | yes |
| `platform_fee` | `LedgerPlatformFee` | platform's share credited to account `platform` | no |
| `withdrawal` | `LedgerWithdrawal` | legacy on-chain withdrawal; no current writer | — |
| `referral_reward` | `LedgerReferralReward` | referrer's share of a platform fee | yes |
| `stripe_deposit` | `LedgerStripeDeposit` | Stripe Checkout deposit, reference `stripe:<checkout_session_id>` | no |
| `stripe_payout` | `LedgerStripePayout` | Stripe Connect withdrawal debit, reference `stripe_withdraw:<id>` | debit (both columns) |
| `invite_credit` | `LedgerInviteCredit` | invite code redemption, reference `invite:<code>` | no |
| `refund` | `LedgerRefund` | reservation/settlement refund; withdrawal principal and fee refunds | reservation/settlement: no; withdrawal refunds: yes |
| `admin_credit` | `LedgerAdminCredit` | `POST /v1/admin/credit` | no |
| `admin_reward` | `LedgerAdminReward` | `POST /v1/admin/reward` | yes |
| `migration` | `LedgerMigration` | balance moved between account identities | both columns move |
| `provider_floor_draw` | `LedgerFloorDraw` | base-rewards epoch draw, reference `<epoch_id>` | yes |

`RewardLedgerTypes = [referral_reward, admin_reward]` — counted as "reward"
rather than "work" earnings on the leaderboard and in `GET /v1/me/summary`
(`coordinator/store/interface.go` `IsRewardLedgerType`).

## Balance primitives

| Store method | `balance_micro_usd` | `withdrawable_micro_usd` | Idempotent | Citation |
|---|---|---|---|---|
| `Credit` | + | — | no | `coordinator/store/postgres.go` (`creditTx`) |
| `CreditWithdrawable` | + | + | no | `creditWithdrawableTx` |
| `CreditWithdrawableOnce` | + | + | on `(account_id, entry_type, reference)` under `pg_advisory_xact_lock` | `CreditWithdrawableOnce` |
| `Debit` | − (fails with `ErrInsufficientBalance` if `balance < amount`) | `LEAST(withdrawable, balance − amount)` | no | `Debit` |
| `CreateStripeWithdrawalWithDebit` | − | − (fails unless `withdrawable >= amount`) | row insert in the same transaction | `CreateStripeWithdrawalWithDebit` |
| `CreditProviderAccount` | + | + | on `provider_earnings.job_id` | `CreditProviderAccount`; index `idx_provider_earnings_job` |
| `SettleProviderFloorDraw` | + | + | on `(provider_key, epoch_id)` | `coordinator/store/postgres_base_rewards.go` |

## Per-key spend caps

| Field | Where | Values | Citation |
|---|---|---|---|
| `limit_usd` | `POST /v1/keys`, `PATCH /v1/keys/{id}` body | `>= 0`; stored as `APIKey.LimitMicroUSD` | `coordinator/api/apikey_handlers.go` (`validateKeyLimitInputs`, `handleCreateAPIKey`) |
| `limit_reset` | same | `none`, `daily`, `weekly`, `monthly` (`KeyResetNone` …); unknown values normalise to `none` | `coordinator/store/apikey.go` (`NormalizeResetWindow`, `KeySpendWindowStart`) |
| enforcement points | `reserveInferenceBalance`, `topUpReservationForInlinedMedia`, `reserveAdditionalForProvider` | soft cap on settled usage | `coordinator/api/inference_admission.go`; `coordinator/api/consumer.go` |

## Service accounts

| Property | Value | Citation |
|---|---|---|
| Role value | `users.role = "service"` (`RoleService`); `PUT /v1/admin/users/role` accepts `"service"` or `""` | `coordinator/store/interface.go`; `coordinator/api/billing_handlers.go` (`handleAdminSetUserRole`) |
| Cost function | `CalculateCostWithOverridesNoMinimum` | `coordinator/api/provider.go` (`handleCompleteAt`) |
| Price | platform price; provider custom prices and the provider top-up are skipped | `handleCompleteAt`; `coordinator/api/consumer.go` (`isServiceConsumer`, `reserveAdditionalForProvider`) |
| Reservation mode | ledger debit, or in-memory hold when `EIGENINFERENCE_SERVICE_RESERVATIONS_ENABLED=true` | `coordinator/api/reservations.go` (`useServiceReservation`) |
| Rate limiter | `Service` ([Constants](#constants)) | `coordinator/ratelimit/config.go` |
| Platform fee | same per-user override mechanism as other accounts | `handleCompleteAt` |

## Stripe Connect withdrawal states

`stripe_withdrawals.status` (`coordinator/api/stripe_withdraw.go`
`handleStripeWithdraw`): `pending` → `transferred` → `paid` \| `failed`.
Connected-account status `users.stripe_account_status`
(`coordinator/api/stripe_payouts.go`): `""` → `pending` → `ready` \|
`restricted` \| `rejected`. Service agreements (`coordinator/billing/stripe_regions.go`):
`full`, `recipient`.

## Base rewards

`coordinator/payments/baserewards/`; enabled only by
`EIGENINFERENCE_BASE_REWARDS=true`.

| Constant | Value | Citation |
|---|---|---|
| `SettlementPeriod` | `5 * time.Minute` | `epoch.go` |
| `FloorPoolBudgetMicroUSD` | see [Constants](#constants) | `alloc.go`, `epoch.go` |
| `workhorseMinGB` … `workhorseMaxGB` | `48` … `96` | `alloc.go` |
| `WorkhorseReserveFrac` | `0.5` | `engine.go` (`DefaultConfig`) |
| `PerAccountCapFrac` | `0` (disabled) | `engine.go` (`DefaultConfig`) |
| `DefaultReductionK` | `0.0` (additive) | `floor.go` |
| `MinUptimeForAvail` / `FullUptimeForAvail` | `0.90` / `1.00` | `floor.go` |
| `defaultGraceSeconds` | `90` (open sessions accrue to `last_seen + grace`) | `engine.go` |
| Health gates | `MemoryPressure < 0.8`; `ThermalState != "critical"`; online; model loaded; attested and trust ≥ minimum; linked account; hardware model known to `mdm.ModelMaxMemoryGB` | `engine.go` (`buildCandidates`) |

Tier table (`floor.go` `floorTiers`; a machine takes the largest tier whose
`MinGB` it meets; below 24 GB → `0`):

| `MinGB` | Floor (µUSD / month) | USD / month |
|---|---|---|
| 512 | `40_000_000` | $40 |
| 192 | `30_000_000` | $30 |
| 128 | `26_000_000` | $26 |
| 96 | `22_000_000` | $22 |
| 64 | `18_000_000` | $18 |
| 48 | `16_000_000` | $16 |
| 32 | `12_000_000` | $12 |
| 24 | `10_000_000` | $10 |

Formulas: `Avail(u) = clamp((u − 0.90) / 0.10, 0, 1)`;
`PeriodFloor = round(TierFloor(memGB) × period/month × Avail)`;
`Draw = max(0, floor − int64(k × earned))` (`floor.go`). Settlement row:
`provider_floor_draws` with `UNIQUE (provider_key, epoch_id)`; mirrored
`provider_earnings` row has `model = 'base_reward'` and
`job_id = floor:<epoch_id>:<provider_key>` (`coordinator/store/postgres_base_rewards.go`
`SettleProviderFloorDraw`).

## Routes

Registered in `coordinator/api/server.go`. "Auth" is the middleware plus any
check inside the handler: `requireAuth` accepts an API key or a Privy JWT;
`requirePrivyAuth` / "Privy" requires a Privy user (`requirePrivyUser`);
"admin" is `isAdminAuthorized` / `requireAdminKey` (`EIGENINFERENCE_ADMIN_KEY`
bearer or a Privy user listed in `EIGENINFERENCE_ADMIN_EMAILS`); "financial" is
the financial rate limiter ([Constants](#constants)).

| Method and path | Auth | Handler |
|---|---|---|
| `GET /v1/payments/balance` | requireAuth | `coordinator/api/consumer.go` (`handleBalance`) → `BalanceResponse` |
| `GET /v1/payments/usage` | requireAuth | `coordinator/api/consumer.go` (`handleUsage`) → `UsageResponse` |
| `GET /v1/provider/earnings` | none; identifies by `?wallet=` / `X-Provider-Wallet` (legacy) | `coordinator/api/consumer.go` (`handleProviderEarnings`) |
| `GET /v1/provider/account-earnings` | requireAuth | `coordinator/api/billing_handlers.go` (`handleAccountEarnings`) |
| `GET /v1/me/summary` | requirePrivyAuth | `coordinator/api/me_handlers.go` (`handleMySummary`) |
| `POST /v1/keys`, `PATCH /v1/keys/{id}` | requirePrivyAuth + financial | `coordinator/api/apikey_handlers.go` (`handleCreateAPIKey`, `handleUpdateAPIKey`) |
| `POST /v1/billing/stripe/create-session` | requireAuth + financial | `coordinator/api/billing_handlers.go` (`handleStripeCreateSession`) |
| `POST /v1/billing/stripe/webhook` | none; `Stripe-Signature` | `handleStripeWebhook` |
| `GET /v1/billing/stripe/session` | requireAuth | `handleStripeSessionStatus` |
| `GET /v1/billing/wallet/balance` | requireAuth | `handleWalletBalance` → `{"credit_balance_micro_usd"}` |
| `GET /v1/billing/methods` | none | `handleBillingMethods` |
| `POST /v1/billing/stripe/onboard` | requireAuth; Privy | `coordinator/api/stripe_payouts.go` (`handleStripeOnboard`) |
| `GET /v1/billing/stripe/status` | requireAuth; Privy | `handleStripeStatus` |
| `POST /v1/billing/withdraw/stripe` | requireAuth; Privy; status `ready` | `coordinator/api/stripe_withdraw.go` (`handleStripeWithdraw`) |
| `GET /v1/billing/stripe/withdrawals` | requireAuth | `coordinator/api/stripe_payouts.go` (`handleStripeWithdrawals`) |
| `POST /v1/billing/stripe/dashboard` | requirePrivyAuth + financial | `handleStripeDashboardLink` |
| `DELETE /v1/billing/stripe/account` | requirePrivyAuth | `handleStripeUnlink` |
| `POST /v1/billing/stripe/connect/webhook` | none; `Stripe-Signature` | `coordinator/api/stripe_payouts_webhooks.go` (`handleStripeConnectWebhook`) |
| `GET /v1/pricing` | none | `coordinator/api/billing_handlers.go` (`handleGetPricing`) |
| `PUT /v1/pricing` | requireAuth; Privy | `handleSetPricing` |
| `DELETE /v1/pricing` | requireAuth; Privy | `handleDeletePricing` |
| `PUT /v1/admin/pricing` | requireAuth; admin | `handleAdminPricing` |
| `PUT /v1/admin/users/role` | requireAuth; admin | `handleAdminSetUserRole` |
| `PUT /v1/admin/users/platform-fee` | requireAuth; admin | `handleAdminSetUserPlatformFee` |
| `POST /v1/admin/models/register` | publishing key (`X-Darkbloom-Publishing-Key` or bearer; `MODEL_REGISTRY_PUBLISHING_KEY`, the admin key, or a stored publishing key) | `coordinator/api/model_registry_handlers.go` (`handleRegisterModel`, `requirePublishingAPIKey`) |
| `POST /v1/referral/register` | requireAuth + financial; Privy | `coordinator/api/billing_handlers.go` (`handleReferralRegister`) |
| `POST /v1/referral/apply` | requireAuth + financial; Privy | `handleReferralApply` |
| `GET /v1/referral/stats` | requireAuth | `handleReferralStats` |
| `GET /v1/referral/info` | requireAuth | `handleReferralInfo` |
| `POST /v1/admin/invite-codes` | requireAuth + financial; admin | `coordinator/api/invite_handlers.go` (`handleAdminCreateInviteCode`) |
| `GET /v1/admin/invite-codes` | requireAuth; admin | `handleAdminListInviteCodes` |
| `DELETE /v1/admin/invite-codes` | requireAuth; admin | `handleAdminDeactivateInviteCode` |
| `POST /v1/invite/redeem` | requireAuth + financial | `handleRedeemInviteCode` |
| `POST /v1/admin/credit` | requireAuth; admin | `coordinator/api/billing_handlers.go` (`handleAdminCredit`) |
| `POST /v1/admin/reward` | requireAuth; admin | `handleAdminReward` |
| `GET /v1/admin/base-rewards` | admin (in handler) | `coordinator/api/base_rewards_handlers.go` (`handleAdminBaseRewards`) |

### `GET /v1/pricing` response

```json
{
  "prices": [
    {"model": "<model id>", "input_price": 30000, "output_price": 165000, "input_usd": "$0.0300", "output_usd": "$0.1650"}
  ],
  "fallback_input_price": 50000,
  "fallback_output_price": 200000,
  "fallback_input_usd": "$0.0500",
  "fallback_output_usd": "$0.2000"
}
```

`prices` lists every `model_prices` row with `account_id = 'platform'`
(`handleGetPricing`).

### `GET /v1/payments/balance` and `GET /v1/payments/usage` responses

`BalanceResponse{balance_micro_usd, balance_usd, withdrawable_micro_usd,
withdrawable_usd}` and `UsageResponse{usage: [UsageEntry{job_id, model,
prompt_tokens, completion_tokens, cost_micro_usd, timestamp}]}`
(`coordinator/api/types/types.go`; `coordinator/payments/payments.go`
`UsageEntry`). `*_usd` strings are `"%.6f"`.

## Environment variables

Defaults and validation live in [configuration.md](configuration.md); this table only maps each variable to its owning section there.

| Variable | Effect | Owner |
|---|---|---|
| `EIGENINFERENCE_STRIPE_SECRET_KEY`, `EIGENINFERENCE_STRIPE_WEBHOOK_SECRET`, `EIGENINFERENCE_STRIPE_SUCCESS_URL`, `EIGENINFERENCE_STRIPE_CANCEL_URL` | Stripe Checkout: API key, webhook signature, redirects | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET`, `EIGENINFERENCE_STRIPE_CONNECT_COUNTRY`, `EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL`, `EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL` | Stripe Connect: webhook signature, platform country for the service-agreement choice (`RequiredServiceAgreement`, `coordinator/billing/stripe_regions.go`), onboarding redirects | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `EIGENINFERENCE_BILLING_MOCK` | mock billing; `Config.Check` rejects it alongside a real Stripe key | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `EIGENINFERENCE_REFERRAL_SHARE_PCT` | referrer share of the platform fee (`ReferralSharePercent`, [Constants](#constants)) | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `EIGENINFERENCE_SERVICE_RESERVATIONS_ENABLED` | in-memory reservation holds for `RoleService` accounts | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `EIGENINFERENCE_BASE_REWARDS`, `EIGENINFERENCE_BASE_REWARDS_K`, `EIGENINFERENCE_BASE_REWARDS_POOL_MICRO`, `EIGENINFERENCE_BASE_REWARDS_MIN_UPTIME`, `EIGENINFERENCE_BASE_REWARDS_ACCOUNT_CAP` | base-rewards engine switch, reduction factor `k`, monthly pool (µUSD), eligibility uptime fraction, per-account cap fraction | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `MNEMONIC`, `EIGENINFERENCE_MNEMONIC` | read by billing config but used for the coordinator's X25519 request-encryption key, not for money | [Auth: admin key, Privy, release key, sender encryption](configuration.md#auth-admin-key-privy-release-key-sender-encryption) |
| `EIGENINFERENCE_ADMIN_KEY`, `EIGENINFERENCE_ADMIN_EMAILS` | admin authorization for admin billing routes (`isAdminAuthorized`, `coordinator/api/release_handlers.go`) | [Auth: admin key, Privy, release key, sender encryption](configuration.md#auth-admin-key-privy-release-key-sender-encryption) |
| `MODEL_REGISTRY_PUBLISHING_KEY` | bootstrap publishing key accepted by `POST /v1/admin/models/register` (`requirePublishingAPIKey`) | [Model registry, releases and R2/CDN](configuration.md#model-registry-releases-and-r2cdn) |
| `EIGENINFERENCE_FINANCIAL_RATE_LIMIT_RPS`, `EIGENINFERENCE_FINANCIAL_RATE_LIMIT_BURST`, `EIGENINFERENCE_SERVICE_RATE_LIMIT_RPS`, `EIGENINFERENCE_SERVICE_RATE_LIMIT_BURST` | financial and service limiters; compiled defaults under [Constants](#constants) | [Routing, admission and TTFT](configuration.md#routing-admission-and-ttft) |

## Global Payouts withdrawals

| Quantity | Policy | Citation |
|---|---|---|
| User fee | Zero for standard bank withdrawals; platform pays Stripe charges | `coordinator/api/global_payouts_withdraw.go` (`handleGlobalPayoutQuote`) |
| USD input | Decimal with at most two fractional digits; $1 to $1,000,000, further constrained by balance and Stripe corridor limits | `coordinator/api/global_payouts_withdraw.go` (`payoutUSDCents`) |
| Local amount | Stripe quote, in destination minor units with explicit currency exponent | `coordinator/api/global_payouts_withdraw.go` (`payoutCurrencyExponent`) |
| Quote validity | At most two minutes, shortened to the Stripe FX lock expiry | `coordinator/api/global_payouts_withdraw.go` (`handleGlobalPayoutQuote`) |
| Retry window without remote ID | Twelve hours, then manual reconciliation without automatic refund | `coordinator/api/global_payouts_reconcile.go` (`syncGlobalPayout`) |
| Reconciliation | One-minute loop, up to 200 records per scan; posted records polled for 90 days and later returns handled by events | `coordinator/api/global_payouts_reconcile.go` (`StartGlobalPayoutReconciler`); `coordinator/store/global_payouts_postgres.go` (`ListGlobalPayoutsToReconcile`) |
