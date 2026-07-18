# Payments and Billing

Darkbloom maintains an internal micro-USD ledger. 1 USD = 1,000,000 micro-USD.

## Ledger

The ledger records usage, charges, platform fees, provider payouts, and
referrals. Implementation:

- `coordinator/payments/pricing.go` — pricing models and per-request cost
  estimation.
- `coordinator/payments/payments.go` — ledger operations.
- `coordinator/api/provider.go` around lines 1640–1944 — settlement path.

## Pricing

Pricing is per-model and stored in the coordinator registry. Consumers are
charged per input/output token. The platform keeps a fee and pays the remainder
to the provider.

Do not hardcode prices in documentation; consult `coordinator/payments/pricing.go`
and the live `/v1/models` response.

## Payment rails

- Stripe Checkout funds the internal ledger.
- Stripe Connect handles provider onboarding and payouts.
- The legacy mnemonic configuration is unrelated to billing; it derives the
  coordinator X25519 request-encryption identity.

## Self-route billing

Self-route requests (to a provider owned by the caller) are free: they skip the
pre-flight reservation, per-key spend cap, charge, platform fee, and provider
payout. A zero-cost usage row is still recorded for transparency.

Code: `coordinator/api/self_route.go`, `coordinator/api/provider.go`
`handleComplete`.

## Referrals

Referral credits are tracked in `coordinator/billing/`.
