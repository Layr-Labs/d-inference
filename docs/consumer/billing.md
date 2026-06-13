# Billing

How Darkbloom prices inference, accepts deposits, and tracks usage.

## Pricing Model

See the dry reference in [`../reference/pricing-model.md`](../reference/pricing-model.md) for rates, resolution order, provider custom prices, service accounts, and per-key caps.

Darkbloom uses **per-token pricing** with no subscription or minimum commitment. Each request is charged based on the final token counts reported by the provider:

```text
cost = (prompt_tokens × input_rate + completion_tokens × output_rate) / 1,000,000
```

Rates are configured in micro-USD per 1M tokens.

### Platform Default Prices

Model-specific prices are set via the admin endpoint `PUT /v1/admin/pricing` and stored under the special `platform` account. Consumers see the effective platform price in `GET /v1/pricing` and in the `pricing` block of `GET /v1/models`.

If a model has no platform price, the fallback rates apply:

| Direction | Fallback rate |
|---|---|
| Input | **$0.05 per 1M tokens** |
| Output | **$0.20 per 1M tokens** |

Fallback constants: [`coordinator/payments/pricing.go:24-29`](https://github.com/eigeninference/d-inference/blob/master/coordinator/payments/pricing.go#L24-L29).

### Minimum Charge

Every charged request is floored at **$0.0001** (100 micro-USD) to avoid rounding a tiny request to zero ([`coordinator/payments/pricing.go:31-32`](https://github.com/eigeninference/d-inference/blob/master/coordinator/payments/pricing.go#L31-L32)).

### Platform Fee

During public alpha the default platform fee is **0%**, so providers receive 100% of the per-token revenue. The global default can be raised post-alpha; per-account overrides are also supported via `PUT /v1/admin/users/platform-fee` ([`coordinator/payments/pricing.go:39-43`](https://github.com/eigeninference/d-inference/blob/master/coordinator/payments/pricing.go#L39-L43)).

### Self-Route is Free

Requests routed to your own provider machine are not charged. See [self-route](../provider/self-route.md).

## Balance and Usage

### Check Balance

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" \
     https://api.darkbloom.dev/v1/payments/balance
```

```json
{
  "balance_micro_usd": 25000000,
  "balance_usd": "25.000000",
  "withdrawable_micro_usd": 0,
  "withdrawable_usd": "0.000000"
}
```

Handler: [`coordinator/api/consumer.go:3704-3717`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L3704-L3717). Note: the old `/v1/me/balance` endpoint has been removed.

### Usage History

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" \
     "https://api.darkbloom.dev/v1/payments/usage?limit=50"
```

```json
{
  "usage": [
    {
      "job_id": "req_abc123",
      "model": "gemma-4-26b",
      "prompt_tokens": 150,
      "completion_tokens": 80,
      "cost_micro_usd": 17700,
      "timestamp": "2024-01-15T10:30:00Z"
    }
  ]
}
```

Handler: [`coordinator/api/consumer.go:3719-3754`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L3719-L3754).

## Deposits

Add credits via Stripe Checkout:

```bash
curl -X POST https://api.darkbloom.dev/v1/billing/stripe/create-session \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"amount_usd": "25.00"}'
```

Response:

```json
{
  "session_id": "sess_abc123",
  "stripe_session": "cs_test_...",
  "url": "https://checkout.stripe.com/...",
  "amount_usd": "25.00",
  "amount_micro_usd": 25000000
}
```

Minimum deposit: **$0.50** ([`coordinator/api/billing_handlers.go:51-55`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/billing_handlers.go#L51-L55)).

The Stripe webhook `POST /v1/billing/stripe/webhook` credits the account after checkout completion ([`coordinator/api/billing_handlers.go:115-187`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/billing_handlers.go#L115-L187)).

## Balance Reservation

Before dispatching a paid request, the coordinator reserves the worst-case cost: an upper-bound prompt token estimate plus the bounded `max_tokens`. After the provider returns the actual token counts, the unused portion is refunded atomically ([`coordinator/api/consumer.go:1438-1465`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L1438-L1465)).

If your balance is too low for the reserved amount, you receive `402 insufficient_funds` even if the actual cost would have been smaller.

## Referral Program

Referrers earn a share of the platform fee on inference by referred users. Because the platform fee is 0% during public alpha, referral payouts are dormant until a non-zero fee is configured ([`coordinator/payments/pricing.go:39-43`](https://github.com/eigeninference/d-inference/blob/master/coordinator/payments/pricing.go#L39-L43)).

- `POST /v1/referral/register` — choose a referral code.
- `POST /v1/referral/apply` — apply someone else's code to your account.
- `GET /v1/referral/stats` and `GET /v1/referral/info` — view activity.

## Per-Key Spending Limits

Set a spend cap when creating an API key:

```bash
curl -X POST https://api.darkbloom.dev/v1/keys \
  -H "Authorization: Bearer YOUR_PRIVY_JWT" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Capped Key",
    "limit_usd": 5.00,
    "limit_reset": "monthly"
  }'
```

Valid reset windows are `none`, `daily`, `weekly`, and `monthly`. When a key hits its cap, requests return `402 insufficient_quota` ([`coordinator/api/consumer.go:3359-3375`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L3359-L3375)).

See [authentication.md](authentication.md) for all key controls.
