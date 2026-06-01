package api

// Billing API handlers for Stripe payments and referral system.
//
// Consumer payment flow (Stripe Checkout):
//   1. User authenticates via Privy JWT
//   2. User creates a Stripe Checkout session
//   3. Stripe webhook confirms payment and credits internal balance
//
// Provider payouts use Stripe Connect Express (bank/card withdrawals).
//
// Endpoints that modify account state (referral, pricing, deposits) require
// Privy authentication to prevent spam. API key auth is accepted for
// read-only endpoints and inference.
//
// The handlers themselves live in per-concern files:
//   - billing_stripe_handlers.go      Stripe deposit/checkout, webhook, wallet, payment methods
//   - referral_handlers.go            referral register/apply/stats/info
//   - pricing_handlers.go             public + provider self-serve pricing
//   - admin_billing_handlers.go       admin pricing/roles/fees/credit/reward
//   - earnings_handlers.go            provider/account earnings
