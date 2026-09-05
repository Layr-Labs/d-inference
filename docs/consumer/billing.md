# Billing: fund an account and keep spend under control

> Last updated: 2026-09-05 · commit `4d9811f7c`

How to add credit, read your balance and usage, cap what a key can spend,
redeem an invite code, and act on a `402`. Why the coordinator behaves this
way — reservations, settlement, the ledger, provider payouts — is explained in
[`architecture/billing.md`](../architecture/billing.md); every constant and
route is tabulated in [`reference/pricing-model.md`](../reference/pricing-model.md).

## Prerequisites

- A Darkbloom account (console sign-in through Privy) and an API key
  (`sk-db-…`) — see [authentication.md](authentication.md). Requests below
  marked **Privy** need the console session token, not an API key.
- Deposits and payouts require the operator's Stripe configuration; if
  `POST /v1/billing/stripe/create-session` returns `503 billing_error`, Stripe is
  not configured on that coordinator.
- Rates are per token, prepaid, with no subscription. `GET /v1/pricing` (no
  auth) returns the platform price for each model and the fallback rates used
  when a model has none; `GET /v1/models` repeats them in its `pricing` block.

## Steps

### 1. Create a Checkout session

```bash
curl -X POST https://api.darkbloom.dev/v1/billing/stripe/create-session \
  -H "Authorization: Bearer sk-db-..." \
  -H "Content-Type: application/json" \
  -d '{"amount_usd": "10.00"}'
```

`amount_usd` is a string and must be at least `0.50`, the Stripe deposit
minimum in [`reference/pricing-model.md` → Constants](../reference/pricing-model.md#constants).
Optional fields:
`email` (prefilled on the Checkout page) and `referral_code` (see step 6). The
response carries the Stripe page to open plus the coordinator's own session id:

```json
{
  "session_id": "3f0e...",
  "stripe_session": "cs_live_...",
  "url": "https://checkout.stripe.com/c/pay/cs_live_...",
  "amount_usd": "10.00",
  "amount_micro_usd": 10000000
}
```

Open `url` and pay. The coordinator does not credit on redirect; it credits
when Stripe delivers `checkout.session.completed` to its webhook, usually
within seconds. The credit lands as a `stripe_deposit` ledger entry on your
spendable balance; deposits are never withdrawable
(`coordinator/api/billing_handlers.go` `handleStripeWebhook`).

In the console, **Buy Credits** on `/billing` reaches the same endpoint through
the same-origin relay `/api/payments/stripe/checkout`, which forwards your Privy
session (`Authorization` header or `privy-token` cookie) — not your API key,
which the browser also sends and the relay ignores
(`console-ui/src/app/api/payments/stripe/checkout/route.ts`).

### 2. Confirm the deposit

```bash
curl "https://api.darkbloom.dev/v1/billing/stripe/session?id=3f0e..." \
  -H "Authorization: Bearer sk-db-..."
```

`status` moves from `pending` to `completed` when the webhook has been
processed (`handleStripeSessionStatus`).

### 3. Read your balance and usage

```bash
curl https://api.darkbloom.dev/v1/payments/balance -H "Authorization: Bearer sk-db-..."
curl https://api.darkbloom.dev/v1/payments/usage   -H "Authorization: Bearer sk-db-..."
```

```json
{"balance_micro_usd": 10000000, "balance_usd": "10.000000",
 "withdrawable_micro_usd": 0, "withdrawable_usd": "0.000000"}
```

`balance_micro_usd` is what requests can spend, in
[micro-USD](../reference/pricing-model.md#units).
`withdrawable_micro_usd` is the part you earned (serving inference, referral
rewards) and can pay out through Stripe Connect; deposits and invite credits
never count toward it, so a pure consumer sees `0`. `GET /v1/payments/usage` lists settled
requests with `job_id`, `model`, `prompt_tokens`, `completion_tokens`,
`cost_micro_usd`, `timestamp` (`coordinator/api/consumer.go` `handleBalance`,
`handleUsage`). Console users get the same figures from `GET /v1/me/summary`
(**Privy**). Usage is a recent-history view, not a complete billing export;
the process retains the newest entries up to the [usage history limit](../reference/pricing-model.md#constants).
Dashboard earnings windows include every row in each window, without the old
5,000-row truncation. Concurrent tabs share one aggregate per account and may
lag by the per-account cache interval
(`coordinator/api/me_summary_cache.go`, `mySummaryWindowsCacheTTL`).

### 4. Understand what a request costs you

Each request is charged
`prompt_tokens × input_price + completion_tokens × output_price` at the
platform price, floored at the per-request minimum, on the token counts the
provider reports. Before dispatch the coordinator reserves the worst case —
your estimated prompt plus the full output bound (your `max_tokens`, or a
model default when you set none; the exact rule and default are in
[pricing-model.md → Formulas](../reference/pricing-model.md#formulas)) — and
refunds the difference after the response. A provider with a custom price above the platform price is paid
for from an extra reservation taken at dispatch. Requests that route to your
own machine ([self-route](../provider/self-route.md)) settle at zero. The
formulas and constants are in [`reference/pricing-model.md` →
Formulas](../reference/pricing-model.md#formulas); what happens to cached
tokens and to the platform fee is stated in
[`architecture/billing.md` → Invariants](../architecture/billing.md#invariants).

Because the reservation uses the output bound, a request can be refused for
insufficient balance even though its settled cost would have fit. Set
`max_tokens` to what you need.

### 5. Cap what a key can spend (**Privy**)

```bash
curl -X POST https://api.darkbloom.dev/v1/keys \
  -H "Authorization: Bearer <privy-access-token>" \
  -H "Content-Type: application/json" \
  -d '{"name": "ci", "limit_usd": 25, "limit_reset": "monthly"}'
```

`limit_usd` is a USD number `>= 0`; `limit_reset` is `none` (lifetime cap),
`daily`, `weekly`, or `monthly`, aligned to UTC midnight, Monday, and the 1st
(`coordinator/store/apikey.go` `KeySpendWindowStart`). Change either later with
`PATCH /v1/keys/{id}`. The cap is checked against the key's settled usage in
the window before each request's reservation; it is a soft sub-cap under your
account balance, so several in-flight requests can together overshoot it by up
to their reservations (`coordinator/api/apikey_handlers.go` `checkKeySpendCap`).
`GET /v1/keys` shows `usage_usd`, `limit_usd`, and `remaining_usd` per key.

### 6. Referral codes

Register a code of your own (3–20 letters, digits, or hyphens, stored
uppercased — the rule is in [`reference/pricing-model.md` → Constants](../reference/pricing-model.md#constants);
**Privy**):

```bash
curl -X POST https://api.darkbloom.dev/v1/referral/register \
  -H "Authorization: Bearer <privy-access-token>" \
  -H "Content-Type: application/json" -d '{"code": "MYCODE"}'
```

A referred user attaches your code once, either by
`POST /v1/referral/apply {"code": "MYCODE"}` (**Privy**) or by passing
`referral_code` on their first Checkout session (step 1); an account can have
one referrer and cannot refer itself. From then on you earn a fixed share of
the platform fee taken on that user's requests, credited as withdrawable
`referral_reward` entries. The share and the fee it applies to are in
[`reference/pricing-model.md` → Formulas](../reference/pricing-model.md#formulas)
and [`architecture/billing.md` → Consumer referral](../architecture/billing.md#consumer-referral);
read those before promising anyone an income. `GET /v1/referral/stats`
returns `code`, `total_referred`, `total_rewards_micro_usd`;
`GET /v1/referral/info` returns `code`, `share_percent`, `referred_by`.

### 7. Redeem an invite code

```bash
curl -X POST https://api.darkbloom.dev/v1/invite/redeem \
  -H "Authorization: Bearer sk-db-..." \
  -H "Content-Type: application/json" -d '{"code": "INV-1a2b3c4d"}'
```

Invite codes are created by Darkbloom staff and carry a fixed amount. A
successful redemption returns `credited_usd` and `balance_usd`; the credit is
spendable but not withdrawable, and each account can redeem a given code once
(`coordinator/api/invite_handlers.go` `handleRedeemInviteCode`).

### 8. High-volume integrations: service accounts

There is no self-service switch. If you route traffic on behalf of many end
users (a gateway or marketplace), ask Darkbloom to mark your account as a
service account. It changes three things: the per-request minimum charge is
dropped, requests are always billed at the platform price regardless of a
provider's custom price, and the request rate limit moves to the service tier.
Details: [`architecture/billing.md` → Service accounts](../architecture/billing.md#service-accounts).

## Verify

- `GET /v1/billing/stripe/session?id=…` shows `"status": "completed"` and
  `GET /v1/payments/balance` has risen by `amount_micro_usd`.
- After a chat completion, `GET /v1/payments/usage` lists the request with its
  `cost_micro_usd`, and the balance has dropped by exactly that amount (the
  unused part of the reservation is refunded in the same settlement).
- `GET /v1/keys` shows `usage_usd` growing on the key you used and
  `remaining_usd` shrinking toward `0`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Paid on Stripe, balance unchanged | Webhook not delivered yet, or the coordinator's webhook secret is wrong | Poll the session status; if it stays `pending` for minutes, contact the operator with `stripe_session` |
| `402` with `error.type` [`insufficient_funds`](../architecture/billing.md#payment-required-responses) | Balance is below the worst-case reservation | Deposit, or lower `max_tokens`; see step 4 |
| `402` with `error.type` [`insufficient_quota`](../architecture/billing.md#payment-required-responses) | Per-key cap reached for the window | `PATCH /v1/keys/{id}` with a higher `limit_usd`, wait for the window to reset, or use another key |
| `402` with `error.type` [`provider_error`](../architecture/billing.md#payment-required-responses) | The only provider that could serve the model has a custom price above the platform price and your balance could not cover the extra reservation | Deposit; the request was not charged |
| `400` `invalid_request_error` on `create-session` about `amount_usd` | Deposit below the [minimum](../reference/pricing-model.md#constants) | Send `amount_usd` at or above the minimum, as a string (step 1) |
| `400` "invalid referral code" on `create-session` | `referral_code` is not a registered code | Drop the field or fix the code |
| `400` `referral_error` "account already has a referrer" / "cannot refer yourself" | One referrer per account; self-referral rejected | — |
| `400` "invite code … is inactive / has expired / has reached max uses" or "account has already redeemed code" | Code exhausted or reused | Ask for a new code |
| `404` `referral_error` "not a registered referrer" on `GET /v1/referral/info` | You have not registered a code | Step 6 |
| `401` `auth_error` on `POST /v1/keys`, `/v1/referral/register`, `/v1/referral/apply` | Called with an API key | Use the Privy access token |
| `429` on `create-session`, key mutations, referral or invite calls | The [financial rate limiter](../reference/pricing-model.md#constants) | Back off for `Retry-After` |
| Balance dropped by more than the response should cost, then recovered | Reservation debited at admission, refund at settlement | Expected; read balance after the response completes |
| `503` `billing_error` | Stripe or the referral service is not configured on this coordinator | Operator issue |

Mechanism for each error, including the exact functions, is in
[`architecture/billing.md` → Failure modes](../architecture/billing.md#failure-modes).

## Related

- [`architecture/billing.md`](../architecture/billing.md) — reservation, settlement, ledger, Stripe, referral, base rewards
- [`reference/pricing-model.md`](../reference/pricing-model.md) — constants, formulas, routes, environment variables
- [`authentication.md`](authentication.md) — creating, rotating, and scoping API keys
- [`models.md`](models.md) — `GET /v1/models` and its `pricing` block
- [`../provider/self-route.md`](../provider/self-route.md) — routing to your own machine, which settles free
- [`../reference/api-contracts.md`](../reference/api-contracts.md) — error envelope and status codes

## Withdraw international earnings

Choose your country of residence in bank setup and use a bank account in that country. Stripe collects bank details and required identification. Available destinations are shown in the country selector; a country being listed still requires successful verification of your account and bank.

For international bank withdrawals, enter a USD amount and select **Review withdrawal**. Review the estimated local deposit, destination, withdrawal fee and expected timing, then select **Confirm withdrawal**. Reviewing does not deduct earnings. An expired estimate must be refreshed. If a response is interrupted, **Check withdrawal** resolves the existing withdrawal before allowing another.

In history, **Sent to bank** means the transfer left Stripe; it can take additional time for your bank to credit it. **Returned to balance** means the transfer was returned and your withdrawable earnings were restored. Your bank can charge additional fees. Existing Connect withdrawals keep their current payout schedule. See the [pricing reference](../reference/pricing-model.md#global-payouts-withdrawals).
