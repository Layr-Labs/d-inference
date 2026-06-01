package api

// Stripe Payouts handlers — bank/card withdrawals via Stripe Connect Express.
//
// This file is the thin remainder of the original stripe_payouts.go; the
// declarations now live in per-concern files (all package api):
//
//   - stripe_payouts_onboard.go  — onboarding + status HTTP handlers.
//   - stripe_payouts_withdraw.go — the withdrawal HTTP handler + list withdrawals.
//   - stripe_payouts_webhook.go  — the Connect webhook dispatch + per-event handlers.
//   - stripe_payouts_status.go   — the status enum/consts + account-status mapping.
//   - stripe_payouts_helpers.go  — pure helpers + compile-time import anchors.
//
// Flow:
//
//  1. Onboard. POST /v1/billing/stripe/onboard creates a Stripe Express
//     connected account for the Privy user (idempotent — reuses an existing
//     stripe_account_id if one is on file), then returns a hosted onboarding
//     URL the frontend redirects them to.
//  2. Status. GET /v1/billing/stripe/status returns the user's current
//     readiness state. Called both on the billing page load and when the user
//     comes back from the hosted onboarding flow so we can refresh from
//     Stripe before the webhook arrives.
//  3. Withdraw. POST /v1/billing/withdraw/stripe debits the ledger by
//     amount_usd, computes the Instant fee (1.5% / $0.50 min) if requested,
//     calls transfers.create then payouts.create, and persists the local
//     withdrawal row. On any Stripe error we re-credit the ledger.
//  4. Webhook. POST /v1/billing/stripe/connect/webhook drives the local state
//     machine via account.updated, payout.paid, payout.failed, transfer.failed.
//     payout.failed and transfer.failed re-credit the user's ledger via
//     LedgerRefund.
