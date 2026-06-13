# Billing and Pricing

Darkbloom uses a prepaid micro-USD ledger. All prices are stored in **micro-USD per 1 million tokens** (1 USD = 1,000,000 micro-USD). The coordinator reserves the worst-case cost before dispatch, then settles the actual cost after the provider reports usage.

Canonical pricing math is in `coordinator/payments/pricing.go`. Settlement is in `coordinator/api/provider.go:handleComplete` (`provider.go:1608-1967`). Balance operations are defined in `coordinator/store/interface.go`.

## Privacy note

Billing requires token counts. The coordinator decrypts the request body in Confidential-VM memory to estimate prompt tokens for the pre-flight reservation and receives final token counts in the provider's `inference_complete` message. Prompt content is not logged or retained. See the canonical privacy model in [`../../AGENTS.md`](../../AGENTS.md).

## Price resolution hierarchy

For each request the coordinator resolves the input and output price in this order (`coordinator/api/provider.go:1677-1684`):

1. **Provider custom price** — `store.GetModelPrice(providerAccountID, model)`, if the provider is linked to an account and the consumer is not a service/wholesale account.
2. **Platform admin price** — `store.GetModelPrice("platform", model)`, set via `PUT /v1/admin/pricing`.
3. **Hardcoded fallback defaults** — `coordinator/payments/pricing.go:23-29`.

Service/wholesale consumers (e.g. OpenRouter, `RoleService`) are always billed at the advertised platform price and are exempt from provider custom pricing (`provider.go:1679-1684`, `consumer.go:974-986`).

## Fallback prices

Defined in `coordinator/payments/pricing.go`:

| Item | Constant | Value |
|---|---|---|
| Input tokens | `DefaultInputPricePerMillion` | `50_000` micro-USD / 1M tokens = **$0.05 / 1M tokens** |
| Output tokens | `DefaultOutputPricePerMillion` | `200_000` micro-USD / 1M tokens = **$0.20 / 1M tokens** |
| Minimum charge | `minimumChargeMicroUSD` | `100` micro-USD = **$0.0001 per request** |
| Platform fee | `platformFeePercent` | **0%** during the public alpha (`pricing.go:43`) |

These defaults apply only to models that have not been priced via the admin API.

## Cost calculation

`CalculateCostWithOverrides` (`pricing.go:82-84`) is the standard path:

```go
inputCost  = promptTokens      * inputRate  / 1_000_000
outputCost = completionTokens * outputRate / 1_000_000
cost       = inputCost + outputCost
if cost < minimumChargeMicroUSD { cost = minimumChargeMicroUSD }
```

Service/wholesale traffic uses `CalculateCostWithOverridesNoMinimum` (`pricing.go:91-93`) so the debit matches the published per-token price exactly, with only a zero-guard for nonzero usage rounded to 0 (`pricing.go:113-118`).

### Platform fee and payout

```go
platformFee   = totalCost * resolveFeePercent(feePercent) / 100
providerPayout = totalCost - platformFee
```

* `resolveFeePercent` (`pricing.go:128-140`) clamps the optional per-account override to `[0, 100]` and falls back to the global default.
* The global default is `0%` (`pricing.go:43`), so the provider receives 100% of revenue unless an account override is set via `PUT /v1/admin/users/platform-fee`.
* A 0% override explicitly waives the fee (`store/interface.go:322-325`).

The platform fee is also the pool for referral rewards. With the default fee at 0%, referral rewards are dormant during the alpha (`pricing.go:39-42`).

## Pre-flight reservation

Before dispatch the consumer handler reserves the worst-case cost:

1. Estimate prompt tokens (`coordinator/api/consumer.go:574-665`).
2. Ensure a `max_tokens` bound is present, defaulting to the model's `max_output_length` or `defaultMaxOutputTokens = 8192` (`consumer.go:864-875`).
3. Call `reservationCost` (`consumer.go:885-888`), which uses the platform admin price if set, otherwise the fallback defaults.
4. Debit the reservation from the consumer's ledger (`consumer.go:1432-1463`).

If the selected provider has a custom price above the platform rate, `reserveAdditionalForProvider` (`consumer.go:988-1021`) charges the difference before the request is dispatched. Service consumers skip this top-up.

## Settlement

When the provider sends `inference_complete`, `handleComplete` (`provider.go:1608-1967`) settles the actual cost against the reservation:

1. Resolve the final price using the hierarchy above.
2. Compute `totalCost` from reported prompt and completion tokens.
3. Apply the platform-fee override for the consumer account.
4. If the request was served by a provider owned by the consumer account, mark it as a free self-route: `totalCost = 0`, `providerPayout = 0` (`provider.go:1706-1733`).
5. If `totalCost > reserved`, attempt to charge the overage. The overage is capped at the reservation amount as a fraud circuit-breaker (provider cannot bill more than 2× the reservation) (`provider.go:1748-1801`).
6. If `totalCost < reserved`, refund the difference (`provider.go:1803-1809`).
7. If there was no reservation (some self-route or admin paths), charge `totalCost` directly.
8. Record usage and, unless it was free self-route, persist a `RecordUsageFullWithPublicModel` row.
9. Credit the provider's linked account with `providerPayout` and credit the platform account with the platform fee (`provider.go:1880-1943`).

Free self-route traffic is excluded from public stats because it is private, owner-only traffic (`provider.go:1856-1866`).

## Ledger entries

Balance changes are recorded as `LedgerEntry` rows (`coordinator/store/interface.go:627-655`). Common entry types for inference:

| Type | Use |
|---|---|
| `charge` | Consumer pays for inference |
| `payout` | Provider credited for serving |
| `platform_fee` | Platform cut (currently 0% by default) |
| `refund` | Reservation refund or failed-withdrawal re-credit |
| `referral_reward` | Referrer earns a share of the platform fee |

Provider earnings are tracked per node via `ProviderEarning` and per account via `CreditProviderAccount` (`store/interface.go:415-417`).

## Custom pricing edge cases

* A provider custom price above the platform rate can result in an overage charge after inference. The consumer's per-key spend cap is re-checked against the provider-specific total before dispatch (`consumer.go:1008-1013`).
* If the consumer lacks balance for the overage, the cost is clamped to the reservation and the provider is paid from the reservation (`provider.go:1770-1790`).
* If an unlinked provider (no `AccountID`) serves a paid request, the platform keeps the provider payout; there is no earning row (`provider.go:1902-1928`).
