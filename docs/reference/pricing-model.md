# Pricing model reference

> Last updated: 2026-10-04

Constants, formulas, enums, routes, and environment variables of the
coordinator's money path, each row cited to the code that defines it. How the
pieces fit together, and what they guarantee, is explained in
[`architecture/billing.md`](../architecture/billing.md); the consumer how-to is
[`consumer/billing.md`](../consumer/billing.md).

## Units

| Quantity | Unit | Citation |
|---|---|---|
| Balances, reservations, ledger amounts, earnings | `int64` micro-USD; 1 USD = 1,000,000 µUSD | `coordinator/payments/payments.go` (package comment) |
| Prices (`input_price`, `output_price`, `cache_read_price`) | µUSD per 1,000,000 tokens | `coordinator/payments/pricing.go` (`DefaultInputPricePerMillion`, `Rates`) |
| Stripe Checkout amount in | `AmountTotal` cents × `10_000` = µUSD | `coordinator/api/billing/stripe_checkout_webhook.go` (`HandleStripeWebhook`) |
| Stripe Connect amount out | `microUSDToCents(µUSD)` integer cents; sub-cent remainder stays with the platform | `coordinator/api/billing/payouts/connect_helpers.go` (`microUSDToCents`); `coordinator/api/billing/payouts/stripe_withdraw.go` (`HandleStripeWithdraw`) |
| OpenRouter model feed (`prompt`, `completion`, `input_cache_read`) | USD per single token = µUSD/1M ÷ 1e12, rendered as a trimmed decimal string (`50000` → `"0.00000005"`) | `coordinator/payments/pricing.go` (`FormatPerTokenUSD`); `coordinator/api/catalog/openrouter_models.go` (`buildModelPricing`) |
| `GET /v1/pricing` `*_usd` fields | `"$%.4f"` of µUSD/1M ÷ 1e6 (USD per 1M tokens) | `coordinator/payments/pricing.go` (`FormatPerMillionUSD`); `coordinator/api/modelprice/price.go`, `coordinator/api/modelprice/price.go`, `coordinator/api/types/types.go` (`ModelPriceQuote`, `RatesQuote`) |

## Constants

| Constant | Value | Meaning | Citation |
|---|---|---|---|
| `usageHistoryLimit` | `100` | Newest in-process usage entries per consumer, oldest first; capacity grows lazily to the limit. Does not prune durable usage or change balances. | `coordinator/payments/payments.go` (`Ledger.RecordUsage`) |
| `DefaultInputPricePerMillion` | `50_000` | fallback input price ($0.05 / 1M tokens) | `coordinator/payments/pricing.go` |
| `DefaultOutputPricePerMillion` | `200_000` | fallback output price ($0.20 / 1M tokens) | `coordinator/payments/pricing.go` |
| `DefaultCacheReadDiscountPercent` | `50` | discount off the input price for prompt tokens served from a provider's prefix cache when the price row sets no `cache_read_price`; `DefaultCacheReadPrice(in) = ⌊in × 50 / 100⌋`, computed without 64-bit overflow and `0` for `in ≤ 0` (fallback rate $0.025 / 1M) | `coordinator/payments/pricing.go` (`DefaultCacheReadPrice`, `RatesFor`) |
| `minimumChargeMicroUSD` | `100` | per-request floor ($0.0001) applied by `Rates.CostWithMinimum`; not applied to service accounts | `coordinator/payments/pricing.go` |
| `platformFeePercent` | see [billing.md, invariant 4](../architecture/billing.md#invariants) | global platform fee when no per-user override is set | `coordinator/payments/pricing.go` |
| `defaultMaxOutputTokens` | `8192` | output bound when the request sets no max-tokens field and the registry has no `max_output_length` | `coordinator/api/inference/consumer.go` |
| `defaultTerminalSettleGrace` | `30 * time.Second` | how long a consumer-disconnected request waits for the provider terminal before refund | `coordinator/api/inference/settlement.go` |
| `MinWithdrawMicroUSD` | `1_000_000` | minimum withdrawal ($1.00) | `coordinator/billing/stripe_connect.go` |
| `InstantFeeBps` | `150` | instant payout fee (1.5%) | `coordinator/billing/stripe_connect.go` |
| `InstantFeeMinMicroUSD` | `500_000` | instant payout fee floor ($0.50) | `coordinator/billing/stripe_connect.go` |
| standard payout fee | `0` | `FeeForMethodMicroUSD("standard", …)` | `coordinator/billing/stripe_connect.go` |
| `stripeRecipientTransferDelay` | `24 * time.Hour` | availability delay of a transfer into a `recipient`-agreement account; sweep-matching cutoff | `coordinator/api/billing/payouts/stripe_payouts_webhooks.go` |
| `stripeReconcileInterval` / `stripeStuckThreshold` / `stripeReconcileBatch` | `1 * time.Hour` / `48 * time.Hour` / `200` | payout reconciler cadence, stuck threshold, rows per pass | `coordinator/api/billing/payouts/stripe_reconcile.go` |
| Stripe deposit minimum | `0.50` USD | `amount_usd` lower bound on `create-session` | `coordinator/api/billing/checkout.go` (`HandleStripeCreateSession`) |
| `ConsumerReferralPercent` | `5` (fixed) | referrer reward as a percent of collected token spend | `coordinator/store/consumer_settlement.go` |
| Referral code | 3–20 ASCII characters, letters/digits/hyphen, no leading or trailing hyphen, uppercased | `validateReferralCode` | `coordinator/billing/referral.go` |
| Invite code default `max_uses` | `1`; auto-generated code `INV-<8 hex>` | `HandleAdminCreateInviteCode` | `coordinator/api/accounts/invite_handlers.go` |
| Financial rate limiter | `0.2` rps, burst `3` | `create-session`, `POST/PATCH/DELETE /v1/keys`, referral register/apply, invite create/redeem, Stripe dashboard link | `coordinator/ratelimit/config.go` (`Financial`) |
| Service rate limiter | `200` rps, burst `600` | `RoleService` accounts | `coordinator/ratelimit/config.go` (`Service`) |
| `FloorPoolBudgetMicroUSD` | `9_000_000_000` | base-rewards monthly pool ($9,000), prorated per epoch by `PeriodBudget` | `coordinator/payments/baserewards/alloc.go`, `epoch.go` |

## Price resolution

| Order | Source | Lookup | Applies to |
|---|---|---|---|
| 1 | provider custom price | `GetModelPrice(provider.AccountID, model)` | non-service consumers only |
| 2 | platform price | `GetModelPrice("platform", model)` | everyone |
| 3 | hardcoded defaults | `DefaultInputPricePerMillion`, `DefaultOutputPricePerMillion` | everyone |

The resolved row becomes `payments.Rates{Input, Output, CacheRead}` through
`RatesFor` (`coordinator/payments/pricing.go`): a row whose `cache_read_price`
is `NULL` bills cached tokens at `DefaultCacheReadPrice(input_price)`; an
explicit value (including `0`) is used verbatim. Settlement:
`coordinator/api/inference/provider_inference.go` (`HandleCompleteAt`). Reservation:
`coordinator/api/inference/consumer.go` (`reservationCost` uses steps 2–3;
`providerReservationCost` uses 1–3 for the dispatched provider).

| Price writer | Route | Validation | Citation |
|---|---|---|---|
| platform | `PUT /v1/admin/pricing` | `input_price > 0`, `output_price > 0`; optional `cache_read_price` in `[0, input_price]` (omitted = unset) | `coordinator/api/billing/pricing.go` (`HandleAdminPricing`); `coordinator/api/modelprice/price.go` (`modelprice.Input.Validate`) |
| platform | `POST /v1/admin/models/register` | `input_price`, `output_price` required and positive; optional `cache_read_price` as above | `coordinator/api/catalog/model_registry_handlers.go` (`HandleRegisterModel`) |
| provider custom | `PUT /v1/pricing`, `DELETE /v1/pricing` | positive; optional `cache_read_price` in `[0, input_price]`; no floor or ceiling relative to the platform price | `coordinator/api/billing/pricing.go` (`HandleSetPricing`, `HandleDeletePricing`) |

Storage: `model_prices(account_id, model, input_price, output_price,
cache_read_price NULL, updated_at)`, primary key `(account_id, model)`
(`coordinator/store/postgres/`; `store.ModelPrice.CacheReadPrice *int64`).

Existing referral codes created by older releases may contain Unicode letters;
applying those codes remains supported. New registration uses ASCII code rules.

## Formulas

For token-promotion requests, referral rewards use only
`ModelTokenReservation.ConsumerCostMicroUSD`; `SponsoredMicroUSD` is excluded
(`coordinator/internal/store/consumersettlement/settlement.go`, `PromotionRecord`).

| Quantity | Formula | Citation |
|---|---|---|
| Raw cost | `(promptTokens − cachedTokens) × inPrice / 1_000_000 + cachedTokens × cacheReadPrice / 1_000_000 + completionTokens × outPrice / 1_000_000`, each term floored to whole µUSD; `cachedTokens` clamped to `[0, promptTokens]`, negative counts and rates bill as `0`, and each product saturates at `math.MaxInt64` instead of wrapping (an absurd provider-reported count then meets the ≤ 2× reservation overage clamp) | `coordinator/payments/pricing.go` (`Rates.Cost`, `termCost`) |
| Cache-read discount | `settle(usage with cachedTokens = 0) − settle(usage)`, where `settle` is the settlement function (`Rates.CostWithMinimum` for direct consumers, `Rates.Cost` for service accounts); emitted as `billing.cache_read_discount_micro_usd` | `CacheReadDiscount` |
| Cost, direct consumers | `max(rawCost, minimumChargeMicroUSD)` | `Rates.CostWithMinimum` |
| Cost, service accounts | `rawCost`; `1` when the tokens are non-zero but the products round to `0` (no per-request minimum) | `Rates.Cost` |
| Cached tokens | `cachedTokens` is the provider's terminal `usage.cached_tokens` after `validCacheUsage` (`0` for a malformed report), the same count the consumer receives as `prompt_tokens_details.cached_tokens`; see [billing.md, invariant 5](../architecture/billing.md#invariants) | `coordinator/internal/inference/cacheusage/cache_usage.go` (`billableUsage`, `validCacheUsage`) |
| Model-token promotion | every prompt token at `inPrice` — a request settled against a grant gets no cache-read discount | `coordinator/internal/inference/promotions/model_token_pricing.go` (`PriceTokens`) |
| Output bound | explicit `max_tokens` \| `max_completion_tokens` \| `max_output_tokens`, else registry `max_output_length`, else `defaultMaxOutputTokens` | `coordinator/api/inference/consumer.go` (`explicitMaxTokens`, `ensureMaxTokensBound`) |
| Reservation | `RatesFor(platform price).CostWithMinimum(Usage{PromptTokens: max(BillingPromptTokens, estimatedPromptTokens), CompletionTokens: outputBound})` — no cache hit assumed, so the reservation prices every prompt token at the input rate and settlement refunds the cache-read discount | `coordinator/api/inference/inference_balance.go` (`reserveInferenceBalance`); `coordinator/api/inference/consumer.go` (`reservationCost`, `reservationUsage`) |
| Provider top-up | `providerReservationCost − reserved` when the dispatched provider's custom price makes it positive; skipped for service consumers | `coordinator/api/inference/consumer.go` (`reserveAdditionalForProvider`) |
| Media top-up | `reservationCost(inlined body) − reserved` when positive | `coordinator/api/inference/inference_balance.go` (`topUpReservationForInlinedMedia`) |
| Overage | `min(totalCost − reserved, reserved)`; debited as `charge` with reference `overage:<request_id>`; on failure `totalCost = reserved` | `coordinator/api/inference/provider_inference.go` (`HandleCompleteAt`) |
| Settlement refund | `reserved − totalCost` when positive; `refund` entry referenced by `<request_id>` | `HandleCompleteAt` |
| Whole-reservation refund | `reserved`; `refund` entry `reservation_refund:<request_id>` | `coordinator/api/inference/consumer.go` (`refundReservedBalance`) |
| Platform fee | `totalCost × resolveFeePercent(user.PlatformFeePercent) / 100`; override clamped to `[0, 100]`, else `platformFeePercent` | `coordinator/payments/pricing.go` (`PlatformFeeWithPercent`, `resolveFeePercent`) |
| Referral reward | `collectedMicroUSD / (100 / ConsumerReferralPercent)` = `floor(collectedMicroUSD / 20)`; additive Darkbloom-funded withdrawable credit, rounded down per request | `coordinator/store/postgres/consumer_settlement.go`, `coordinator/store/memory/consumer_settlement.go` (`FinalizeConsumerCharge`) |
| Referral basis | Actual collected token charge after reservation clamp/refund/debit handling; zero for free or uncollected usage; attribution is captured at settlement, with no historical backfill | `coordinator/internal/store/consumersettlement/settlement.go` (`Cost`); `coordinator/store/postgres/consumer_settlement.go` (`FinalizeConsumerCharge`) |
| Provider payout | `totalCost − platformFee` | `coordinator/payments/pricing.go` (`ProviderPayoutWithPercent`) |
| Withdrawal fee | `0` (standard); `max(gross × InstantFeeBps / 10_000, InstantFeeMinMicroUSD)` (instant) | `coordinator/billing/stripe_connect.go` (`FeeForMethodMicroUSD`) |
| Withdrawal net | `gross − fee`, transferred as `microUSDToCents(net)`; must be ≥ 1 cent | `coordinator/api/billing/payouts/stripe_withdraw.go` (`HandleStripeWithdraw`) |
| Key spend | `Σ usage.cost_micro_usd` for the key since `KeySpendWindowStart(limit_reset, now)`; request rejected when `spend + additional > LimitMicroUSD` | `coordinator/store/postgres/` (`KeySpendSince`); `coordinator/api/inference/key_policy.go` (`checkKeySpendCap`) |

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
| `referral_reward` | `LedgerReferralReward` | referrer reward on collected token spend | yes |
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
| `Credit` | + | — | no | `coordinator/store/postgres/` (`creditTx`) |
| `CreditWithdrawable` | + | + | no | `creditWithdrawableTx` |
| `CreditWithdrawableOnce` | + | + | on `(account_id, entry_type, reference)` under `pg_advisory_xact_lock` | `CreditWithdrawableOnce` |
| `Debit` | − (fails with `ErrInsufficientBalance` if `balance < amount`) | `LEAST(withdrawable, balance − amount)` | no | `Debit` |
| `CreateStripeWithdrawalWithDebit` | − | − (fails unless `withdrawable >= amount`) | row insert in the same transaction | `CreateStripeWithdrawalWithDebit` |
| `CreditProviderAccount` | + | + | on `provider_earnings.job_id` | `CreditProviderAccount`; index `idx_provider_earnings_job` |
| `FinalizeConsumerCharge` | consumer adjustment; + reward to referrer | consumer debit cap; + reward to referrer | on `consumer_charge_settlements.job_id`; consumer settlement and reward share one transaction | `coordinator/store/postgres/consumer_settlement.go` |
| `SettleProviderFloorDraw` | + | + | on `(provider_key, epoch_id)` | `coordinator/store/postgres/base_rewards.go` |

## Per-key spend caps

| Field | Where | Values | Citation |
|---|---|---|---|
| `limit_usd` | `POST /v1/keys`, `PATCH /v1/keys/{id}` body | `>= 0`; stored as `APIKey.LimitMicroUSD` | `coordinator/api/access/keys/handlers.go`, `coordinator/api/access/keys/handlers.go`, `coordinator/api/access/keys/request.go` (`validateKeyLimitInputs`, `HandleCreateAPIKey`) |
| `limit_reset` | same | `none`, `daily`, `weekly`, `monthly` (`KeyResetNone` …); unknown values normalise to `none` | `coordinator/store/apikey.go` (`NormalizeResetWindow`, `KeySpendWindowStart`) |
| enforcement points | `reserveInferenceBalance`, `topUpReservationForInlinedMedia`, `reserveAdditionalForProvider` | soft cap on settled usage | `coordinator/api/inference/inference_balance.go`; `coordinator/api/inference/consumer.go` |

## Service accounts

| Property | Value | Citation |
|---|---|---|
| Role value | `users.role = "service"` (`RoleService`); `PUT /v1/admin/users/role` accepts `"service"` or `""` | `coordinator/store/interface.go`; `coordinator/api/accounts/admin_users.go` (`HandleAdminSetUserRole`) |
| Cost function | `Rates.Cost` (no per-request minimum) | `coordinator/api/inference/provider_inference.go` (`HandleCompleteAt`) |
| Price | platform price; provider custom prices and the provider top-up are skipped | `HandleCompleteAt`; `coordinator/api/inference/consumer.go` (`isServiceConsumer`, `reserveAdditionalForProvider`) |
| Reservation mode | ledger debit, or in-memory hold when `EIGENINFERENCE_SERVICE_RESERVATIONS_ENABLED=true` | `coordinator/api/inference/reservations.go` (`useServiceReservation`) |
| Rate limiter | `Service` ([Constants](#constants)) | `coordinator/ratelimit/config.go` |
| Platform fee | same per-user override mechanism as other accounts | `HandleCompleteAt` |

## Stripe Connect withdrawal states

`stripe_withdrawals.status` (`coordinator/api/billing/payouts/stripe_withdraw.go`
`HandleStripeWithdraw`): `pending` → `transferred` → `paid` \| `failed`.
Connected-account status `users.stripe_account_status`
(`coordinator/api/billing/payouts/`): `""` → `pending` → `ready` \|
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
| `FloorDrawBatchLimit` | `4096` pending rows; a larger plan returns an error without truncation or credit | `coordinator/store/floor_draw_batch.go` |
| Health gates | Current complete public serving authorization; memory/thermal health and loaded-model readiness; linked account; qualified hardware capped by `hardware.ModelMaxMemoryGB` | `machine_candidates.go` (`rewardSnapshotEligible`, `rewardMemoryGB`) |

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
`job_id = floor:<epoch_id>:<provider_key>` (`coordinator/store/postgres/base_rewards.go`
`SettleProviderFloorDraw`).

`settleCandidatePlan` commits all pending rows atomically through `FloorDrawBatchStore`, rechecking current session authorization before each planned credit and before commit. A late rejection rolls back the pending plan and triggers reallocation under the same pool/account caps. Canonical identities, endpoint continuity and prior finalized rows follow the [provider authorization contract](provider-authorization.md#machine-identity-and-base-rewards). Code: `coordinator/payments/baserewards/settlement_plan.go`, `coordinator/store/floor_draw_batch.go`.

## Routes

Registered in `coordinator/api/routes.go`. "Auth" is the middleware plus any
check inside the handler: `RequireAuth` accepts an API key or a Privy JWT;
`RequirePrivyAuth` / "Privy" requires a Privy user (`RequirePrivyUser`);
"admin" is `IsAdminAuthorized` / `RequireAdminKey` (`EIGENINFERENCE_ADMIN_KEY`
bearer or a Privy user listed in `EIGENINFERENCE_ADMIN_EMAILS`); "financial" is
the financial rate limiter ([Constants](#constants)).

| Method and path | Auth | Handler |
|---|---|---|
| `GET /v1/payments/balance` | requireAuth | `coordinator/api/billing/account.go` (`HandleBalance`) → `BalanceResponse` |
| `GET /v1/payments/usage` | requireAuth | `coordinator/api/billing/account.go` (`HandleUsage`) → `UsageResponse` |
| `GET /v1/provider/account-earnings` | requireAuth | `coordinator/api/billing/earnings.go` (`HandleAccountEarnings`) |
| `GET /v1/me/summary` | requirePrivyAuth | `coordinator/api/accounts/summary.go` (`HandleMySummary`) |
| `POST /v1/keys`, `PATCH /v1/keys/{id}` | requirePrivyAuth + financial | `coordinator/api/access/keys/handlers.go` (`HandleCreateAPIKey`, `HandleUpdateAPIKey`) |
| `POST /v1/billing/stripe/create-session` | requireAuth + financial | `coordinator/api/billing/checkout.go` (`HandleStripeCreateSession`) |
| `POST /v1/billing/stripe/webhook` | none; `Stripe-Signature` | `HandleStripeWebhook` |
| `GET /v1/billing/stripe/session` | requireAuth | `HandleStripeSessionStatus` |
| `GET /v1/billing/wallet/balance` | requireAuth | `HandleWalletBalance` → `{"credit_balance_micro_usd"}` |
| `GET /v1/billing/methods` | none | `HandleBillingMethods` |
| `POST /v1/billing/stripe/onboard` | requireAuth; Privy | `coordinator/api/billing/payouts/connect_onboarding.go` (`HandleStripeOnboard`) |
| `GET /v1/billing/stripe/status` | requireAuth; Privy | `HandleStripeStatus` |
| `POST /v1/billing/withdraw/stripe` | requireAuth; Privy; status `ready` | `coordinator/api/billing/payouts/stripe_withdraw.go` (`HandleStripeWithdraw`) |
| `GET /v1/billing/stripe/withdrawals` | requireAuth | `coordinator/api/billing/payouts/history.go` (`HandleStripeWithdrawals`) |
| `POST /v1/billing/stripe/dashboard` | requirePrivyAuth + financial | `HandleStripeDashboardLink` |
| `DELETE /v1/billing/stripe/account` | requirePrivyAuth | `HandleStripeUnlink` |
| `POST /v1/billing/stripe/connect/webhook` | none; `Stripe-Signature` | `coordinator/api/billing/payouts/stripe_payouts_webhooks.go` (`HandleStripeConnectWebhook`) |
| `GET /v1/pricing` | none | `coordinator/api/billing/pricing.go` (`HandleGetPricing`) |
| `PUT /v1/pricing` | requireAuth; Privy | `HandleSetPricing` |
| `DELETE /v1/pricing` | requireAuth; Privy | `HandleDeletePricing` |
| `PUT /v1/admin/pricing` | requireAuth; admin | `HandleAdminPricing` |
| `PUT /v1/admin/users/role` | requireAuth; admin | `HandleAdminSetUserRole` |
| `PUT /v1/admin/users/platform-fee` | requireAuth; admin | `HandleAdminSetUserPlatformFee` |
| `POST /v1/admin/models/register` | publishing key (`X-Darkbloom-Publishing-Key` or bearer; `MODEL_REGISTRY_PUBLISHING_KEY`, the admin key, or a stored publishing key) | `coordinator/api/access/publishing.go`, `coordinator/api/access/publishing.go`, `coordinator/api/catalog/model_registry_handlers.go` (`HandleRegisterModel`, `RequirePublishingAPIKey`) |
| `POST /v1/referral/register` | requirePrivyAuth + financial | `coordinator/api/billing/referrals.go` (`HandleReferralRegister`) |
| `POST /v1/referral/apply` | requirePrivyAuth + financial | `HandleReferralApply` |
| `GET /v1/referral/stats` | requireAuth | `HandleReferralStats` |
| `GET /v1/referral/info` | requireAuth | `HandleReferralInfo` |
| `POST /v1/admin/invite-codes` | requireAuth + financial; admin | `coordinator/api/accounts/invite_handlers.go` (`HandleAdminCreateInviteCode`) |
| `GET /v1/admin/invite-codes` | requireAuth; admin | `HandleAdminListInviteCodes` |
| `DELETE /v1/admin/invite-codes` | requireAuth; admin | `HandleAdminDeactivateInviteCode` |
| `POST /v1/invite/redeem` | requireAuth + financial | `HandleRedeemInviteCode` |
| `POST /v1/admin/credit` | requireAuth; admin | `coordinator/api/billing/admin_balance_adjustment.go` (`HandleAdminCredit`) |
| `POST /v1/admin/reward` | requireAuth; admin | `HandleAdminReward` |
| `GET /v1/admin/base-rewards` | admin (in handler) | `coordinator/api/billing/base_rewards_handlers.go` (`HandleAdminBaseRewards`) |

### `GET /v1/pricing` response

```json
{
  "prices": [
    {"model": "<model id>", "input_price": 30000, "output_price": 165000, "cache_read_price": 15000,
     "input_usd": "$0.0300", "output_usd": "$0.1650", "cache_read_usd": "$0.0150"}
  ],
  "fallback_input_price": 50000,
  "fallback_output_price": 200000,
  "fallback_cache_read_price": 25000,
  "fallback_input_usd": "$0.0500",
  "fallback_output_usd": "$0.2000",
  "fallback_cache_read_usd": "$0.0250"
}
```

`prices` lists every `model_prices` row with `account_id = 'platform'`
(`HandleGetPricing`). `cache_read_price` is the effective rate cached prompt
tokens settle at — the stored value, or `DefaultCacheReadPrice(input_price)`
when the row sets none (`ModelPriceQuote`, `coordinator/api/types/types.go`;
response shape `types.PricingResponse`).
The OpenRouter feed advertises the same figure as `pricing.input_cache_read`.

The feed (`GET /v1/models/openrouter`) is OpenRouter's legacy flat provider
format — a `pricing` object of USD-per-unit decimal strings (`prompt`,
`completion`, `image`, `request`, `input_cache_read`) — which OpenRouter keeps
supported for existing integrations
([legacy format](https://openrouter.ai/docs/guides/community/for-providers-legacy)).
That schema has no cache-write key, and none is needed: caching is
provider-initiated and writes are not billed. OpenRouter's current provider
format ([provider integration](https://openrouter.ai/docs/guides/community/for-providers))
nests `pricing` arrays on each input modality; there the same rate would be a
`cached_prompt` entry with `implicit: true` (provider-initiated caching), and
unbilled SKUs are omitted rather than sent as `"0"`. Consumers see the cached
count as `usage.prompt_tokens_details.cached_tokens` (Chat Completions) or
`usage.input_tokens_details.cached_tokens` (Responses), the fields OpenRouter
documents for cache reads
([prompt caching](https://openrouter.ai/docs/guides/best-practices/prompt-caching)).

### `GET /v1/payments/balance` and `GET /v1/payments/usage` responses

`BalanceResponse{balance_micro_usd, balance_usd, withdrawable_micro_usd,
withdrawable_usd}` and `UsageResponse{usage: [UsageEntry{job_id, model,
prompt_tokens, cached_tokens, completion_tokens, cost_micro_usd, timestamp}]}`
(`coordinator/api/types/types.go`; `coordinator/payments/payments.go`
`UsageEntry`). `cached_tokens` (omitted when `0`) is the subset of
`prompt_tokens` billed at the cache-read rate; it is persisted as
`usage.cached_tokens` (`coordinator/store/postgres/` `RecordUsage`). `*_usd`
strings are `"%.6f"`.

## Environment variables

Defaults and validation live in [configuration.md](configuration.md); this table only maps each variable to its owning section there.

| Variable | Effect | Owner |
|---|---|---|
| `EIGENINFERENCE_STRIPE_SECRET_KEY`, `EIGENINFERENCE_STRIPE_WEBHOOK_SECRET`, `EIGENINFERENCE_STRIPE_SUCCESS_URL`, `EIGENINFERENCE_STRIPE_CANCEL_URL` | Stripe Checkout: API key, webhook signature, redirects | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET`, `EIGENINFERENCE_STRIPE_CONNECT_COUNTRY`, `EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL`, `EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL` | Stripe Connect: webhook signature, platform country for the service-agreement choice (`RequiredServiceAgreement`, `coordinator/billing/stripe_regions.go`), onboarding redirects | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `EIGENINFERENCE_BILLING_MOCK` | mock billing; `Config.Check` rejects it alongside a real Stripe key | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `EIGENINFERENCE_SERVICE_RESERVATIONS_ENABLED` | in-memory reservation holds for `RoleService` accounts | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `EIGENINFERENCE_BASE_REWARDS`, `EIGENINFERENCE_BASE_REWARDS_K`, `EIGENINFERENCE_BASE_REWARDS_POOL_MICRO`, `EIGENINFERENCE_BASE_REWARDS_MIN_UPTIME`, `EIGENINFERENCE_BASE_REWARDS_ACCOUNT_CAP` | base-rewards engine switch, reduction factor `k`, monthly pool (µUSD), eligibility uptime fraction, per-account cap fraction | [Billing, Stripe and base rewards](configuration.md#billing-stripe-and-base-rewards) |
| `MNEMONIC`, `EIGENINFERENCE_MNEMONIC` | read by billing config but used for the coordinator's X25519 request-encryption key, not for money | [Auth: admin key, Privy, release key, sender encryption](configuration.md#auth-admin-key-privy-release-key-sender-encryption) |
| `EIGENINFERENCE_ADMIN_KEY`, `EIGENINFERENCE_ADMIN_EMAILS` | admin authorization for admin billing routes (`IsAdminAuthorized`, `coordinator/api/access/authorize.go`) | [Auth: admin key, Privy, release key, sender encryption](configuration.md#auth-admin-key-privy-release-key-sender-encryption) |
| `MODEL_REGISTRY_PUBLISHING_KEY` | bootstrap publishing key accepted by `POST /v1/admin/models/register` (`RequirePublishingAPIKey`) | [Model registry, releases and R2/CDN](configuration.md#model-registry-releases-and-r2cdn) |
| `EIGENINFERENCE_FINANCIAL_RATE_LIMIT_RPS`, `EIGENINFERENCE_FINANCIAL_RATE_LIMIT_BURST`, `EIGENINFERENCE_SERVICE_RATE_LIMIT_RPS`, `EIGENINFERENCE_SERVICE_RATE_LIMIT_BURST` | financial and service limiters; compiled defaults under [Constants](#constants) | [Routing, admission and TTFT](configuration.md#routing-admission-and-ttft) |

## Global Payouts withdrawals

| Quantity | Policy | Citation |
|---|---|---|
| User fee | Zero for standard bank withdrawals; platform pays Stripe charges | `coordinator/api/billing/payouts/global_payouts_withdraw.go` (`HandleGlobalPayoutQuote`) |
| USD input | Decimal with at most two fractional digits; $1 to $1,000,000, further constrained by balance and published recipient limits in local currency | `coordinator/api/billing/payouts/global_payouts_withdraw.go` (`payoutUSDCents`) |
| Local amount | Stripe quote, in destination minor units with explicit currency exponent | `coordinator/api/billing/payouts/global_payouts_withdraw.go` (`payoutCurrencyExponent`) |
| Quote validity | At most two minutes, shortened to the Stripe FX lock expiry | `coordinator/api/billing/payouts/global_payouts_withdraw.go` (`HandleGlobalPayoutQuote`) |
| Quote cleanup | Up to 1,000 expired, never-confirmed quotes per minute; confirmed withdrawals are retained | `coordinator/store/` (`PruneExpiredGlobalPayoutQuotes`); `coordinator/api/billing/payouts/global_payouts_reconcile.go` (`StartGlobalPayoutReconciler`) |
| Retry window without remote ID | Twelve hours, then `manual_reconciliation_required`: excluded from automatic scans and claims, without refund | `coordinator/api/billing/payouts/global_payouts_reconcile.go` (`syncGlobalPayout`) |
| Reconciliation | One-minute loop, up to 200 records per scan; posted records polled for 90 days and later returns handled by events | `coordinator/api/billing/payouts/global_payouts_reconcile.go` (`StartGlobalPayoutReconciler`); `coordinator/store/postgres/global_payouts.go` (`ListGlobalPayoutsToReconcile`) |

Published recipient bounds are stored in `coordinator/billing/globalpayouts/recipient_limits.go` (`Country.Limits`) from [Stripe's recipient minimums and maximums](https://docs.stripe.com/global-payouts/send-money#recipient-minimums). The API reports the local-currency threshold and validates the credited amount; direct pre-quote comparison is possible for USD destinations. The private payout row retains Stripe's `estimated_fees` as `estimated_stripe_fees` for operator cost review (`coordinator/api/billing/payouts/global_payouts_withdraw.go`, `HandleGlobalPayoutQuote`).

## Promotional model tokens

| Rule | Contract | Code |
|---|---|---|
| Allocation | Explicit claim, one grant per account/model; campaign claim cap and persisted signup cutoff; start-inclusive/end-exclusive claim window; issued tokens never expire | `coordinator/store/model_token_promotions.go` (`ModelTokenPromotion`) |
| Token unit | Prompt plus completion tokens, including cached input and generated reasoning as reported in usage | `coordinator/internal/inference/promotions/model_token_settlement.go` (`Engine.Settle`) |
| Coverage | Input first, then output; fully covered usage costs the consumer zero | `coordinator/internal/inference/promotions/model_token_admission.go` (`quote`) |
| Paid fallback | Uncovered tokens use paid balance; the normal request minimum applies when any tokens are paid | `coordinator/internal/inference/promotions/model_token_admission.go` (`quote`) |
| Provider earnings | Sponsored portion uses exact platform token price and fee share, with no request or one-micro-dollar payout floor; fractional earnings carry across requests per provider account. Paid portion retains its funded minimum. Same-account sponsored serving produces no payout | `coordinator/api/inference/provider_inference.go` (`handleComplete`) |
| Fractional payout storage | Remainders use 1/100000000 of a micro-dollar; whole units become withdrawable atomically with grant settlement; replay never adds the fraction twice | `coordinator/store/model_token_earnings.go` (`ModelTokenPayoutScale`, `carryModelTokenEarning`) |
| Zero-token completion | Reject any nonzero charge or payout; release token/cash holds | `coordinator/store/model_token_promotions.go` (`promotionSettlement`) |
| Settlement reconciliation | Resume usage, key spend and fee accounting once using the stored consumer cost; insufficient cash closes and refunds holds | `coordinator/api/inference/completion_accounting.go` (`completionAccounting`); `coordinator/internal/inference/promotions/model_token_settlement.go` (`abandon`) |
| Reservation recovery | Renew every 30 seconds; reclaim after ten minutes without renewal | `coordinator/api/inference/model_token_engine.go` (`RunModelTokenMaintenance`) delegates to `coordinator/internal/inference/promotions/model_token_maintenance.go` (`Engine.Run`, `Engine.Maintain`, `modelTokenLeaseTimeout`) |

Configure using the [model token promotion runbook](../operations/model-token-promotions.md).

## Global-only bank payout funding

The cutover preserves the existing user-facing standard withdrawal fee and
minimum; it does not introduce instant-card payouts. `RequiredFundingCents`
(`coordinator/billing/globalpayouts/funding.go`) checks the financial account's
available USD against principal plus rounded-up quoted USD Stripe fees before
the first debit. The platform pays these fees. This is an availability check,
not a reservation: definitive send rejection still refunds atomically.

Confirmed Connect rejections refund gross principal and mark the row refunded in
one transaction (`coordinator/store/postgres/stripe_settlement.go`,
`RefundRejectedStripeWithdrawal`). Historical failures without a verified
rejection marker are not automatically credited; follow the
[cutover runbook](../operations/stripe-migration.md).
