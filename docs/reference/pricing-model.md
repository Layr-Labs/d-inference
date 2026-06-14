# Pricing Model

Darkbloom's pricing is expressed in **micro-USD** (1 USD = 1,000,000 micro-USD). Canonical code: [`coordinator/payments/pricing.go`](../../coordinator/payments/pricing.go), billing handlers in [`coordinator/api/billing_handlers.go`](../../coordinator/api/billing_handlers.go), reservation logic in [`coordinator/api/consumer.go`](../../coordinator/api/consumer.go), and account metadata in [`coordinator/store/interface.go`](../../coordinator/store/interface.go).

## Unit

- 1 micro-USD = $0.000001.
- All ledger entries, reservations, provider payouts, and API price fields use micro-USD.
- USD display strings in API responses divide by 1,000,000.

## Price resolution order

When billing a completed inference request, the coordinator resolves the price per model in this order:

1. **Provider custom price** — `store.GetModelPrice(providerAccountID, model)`
2. **Platform admin price** — `store.GetModelPrice("platform", model)`
3. **Fallback defaults** — constants in [`pricing.go`](../../coordinator/payments/pricing.go)

See [`CalculateCostWithOverrides`](../../coordinator/payments/pricing.go) and the reservation path in [`consumer.go:988-1021`](../../coordinator/api/consumer.go).

## Fallback defaults

| Rate | micro-USD per 1M tokens | USD per 1M tokens |
|---|---|---|
| Input (`DefaultInputPricePerMillion`) | 50,000 | $0.05 |
| Output (`DefaultOutputPricePerMillion`) | 200,000 | $0.20 |

Defined in [`pricing.go:23-29`](../../coordinator/payments/pricing.go).

## Per-request minimum

Every inference request is charged at least `minimumChargeMicroUSD = 100` micro-USD ($0.0001). See [`pricing.go:31-32`](../../coordinator/payments/pricing.go) and [`CalculateCost`](../../coordinator/payments/pricing.go).

Wholesale / service channels may use `CalculateCostWithOverridesNoMinimum`, which floors only at 1 micro-USD for non-zero usage to avoid giving away small requests for free. See [`pricing.go:86-120`](../../coordinator/payments/pricing.go).

## Platform fee

The platform routing fee is a percentage of the total cost deducted from provider payout.

| Source | Default | Override path |
|---|---|---|
| Global default | `platformFeePercent = 0%` | [`pricing.go:43`](../../coordinator/payments/pricing.go) |
| Per-account | `User.PlatformFeePercent` | `PUT /v1/admin/users/platform-fee` |

`resolveFeePercent` clamps overrides to `[0, 100]`. See [`pricing.go:128-140`](../../coordinator/payments/pricing.go).

```
platform_fee = total_cost * fee_percent / 100
provider_payout = total_cost - platform_fee
```

The global default is 0% during the public alpha, so providers receive 100% of the advertised price. Referral payouts are a share of the platform fee pool and are therefore dormant while the fee is 0%.

## Provider custom pricing

Linked providers can set per-model prices for their own account via:

| Endpoint | Method | Auth | Effect |
|---|---|---|---|
| `/v1/pricing` | PUT | Privy JWT | Set custom input/output price for caller's account |
| `/v1/pricing` | DELETE | Privy JWT | Revert to platform default for caller's account |

Platform defaults are set by admins via `PUT /v1/admin/pricing`. All price inputs must be positive integers (micro-USD per 1M tokens). See [`billing_handlers.go:496-565`](../../coordinator/api/billing_handlers.go).

### Reservation top-up

At dispatch, the consumer's pre-flight reservation is computed at the platform price. If the selected provider has a custom price above the platform price, the coordinator attempts to charge the difference to the consumer's ledger. If the consumer lacks sufficient balance, that provider is excluded and dispatch retries with another candidate. See [`reserveAdditionalForProvider`](../../coordinator/api/consumer.go).

## Service accounts

Accounts with `User.Role = "service"` (`store.RoleService`) are trusted upstream aggregators (e.g. OpenRouter). They receive:

- Elevated or bypassed RPM/ITPM/OTPM limits via `serviceRateLimiter` / `serviceTokenLimiter`.
- Billing at the advertised platform price: the provider custom-price reservation top-up is skipped, because the actual settlement uses the platform price. See [`isServiceConsumer`](../../coordinator/api/consumer.go) and [`reserveAdditionalForProvider`](../../coordinator/api/consumer.go).

Service role is granted by admin via `PUT /v1/admin/users/role` with `{"role": "service"}`. See [`billing_handlers.go:409-447`](../../coordinator/api/billing_handlers.go).

## Per-key spend caps

API keys may carry a spend cap independent of the account balance:

| Field | Type | Meaning |
|---|---|---|
| `limit_micro_usd` | integer | Max spend in the reset window |
| `limit_reset` | string | `none`, `daily`, `weekly`, `monthly` |

The cap is enforced twice: before the platform-price reservation and again before a provider custom-price top-up, so a capped key cannot be pushed over its limit by an expensive provider. See [`consumer.go:1447-1449`](../../coordinator/api/consumer.go) and [`consumer.go:1008-1013`](../../coordinator/api/consumer.go).

## Pricing API responses

### `GET /v1/pricing`

```json
{
  "prices": [
    {
      "model": "gemma-4-26b",
      "input_price": 30000,
      "output_price": 165000,
      "input_usd": "$0.0300",
      "output_usd": "$0.1650"
    }
  ],
  "fallback_input_price": 50000,
  "fallback_output_price": 200000,
  "fallback_input_usd": "$0.0500",
  "fallback_output_usd": "$0.2000"
}
```

See [`handleGetPricing`](../../coordinator/api/billing_handlers.go).

## Stripe conversion

Stripe amounts are in cents; the coordinator converts to micro-USD:

- Deposit creation: `amount_micro_usd = amount_usd * 1_000_000`
- Webhook completion: `amount_micro_usd = amount_total_cents * 10_000`

See [`billing_handlers.go:67-113`](../../coordinator/api/billing_handlers.go) and [`billing_handlers.go:166`](../../coordinator/api/billing_handlers.go).

## OpenRouter per-token formatting

The `/v1/models` and `/v1/models/openrouter` feeds express prices as USD-per-single-token strings:

```
per_token_usd = micro_usd_per_million / 1e12
```

Implemented in [`payments.FormatPerTokenUSD`](../../coordinator/payments/pricing.go). Example: 50,000 micro-USD/1M tokens → `"0.00000005"`.
