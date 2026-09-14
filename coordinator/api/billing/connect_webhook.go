package billing

import (
	"encoding/json"
	"io"
	"net/http"

	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
)

// StripeConnectWebhook handles POST /v1/billing/stripe/connect/webhook.
// Drives the local withdrawal state machine for Connect events. This is a
// separate endpoint from the Checkout webhook because Stripe lets you
// configure per-endpoint signing secrets.
//
// Transient store failures return a non-2xx so Stripe redelivers the event;
// malformed payloads and business no-ops are acked with 200 (redelivery
// cannot fix those).
func (s *Controller) StripeConnectWebhook(w http.ResponseWriter, r *http.Request) {
	if s.billing() == nil || s.billing().StripeConnect() == nil {
		http.Error(w, "Stripe Connect not configured", http.StatusServiceUnavailable)
		return
	}

	payload, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	sig := r.Header.Get("Stripe-Signature")
	event, err := s.billing().StripeConnect().VerifyConnectWebhookSignature(payload, sig)
	if err != nil {
		s.logger.Warn("stripe connect webhook: signature verification failed", "error", err)
		http.Error(w, "invalid signature", http.StatusBadRequest)
		return
	}

	// Connect webhooks include the connected account ID at the top level
	// (event.account in Stripe's payload). We re-parse the raw payload to
	// pull it out; the WebhookEvent struct only exposes Type + Data.
	var envelope struct {
		Account string `json:"account"`
	}
	_ = json.Unmarshal(payload, &envelope)

	var handleErr error
	switch event.Type {
	case "account.updated":
		// Best-effort mirror: account.updated recurs on every account change
		// and the status endpoint re-syncs on page load, so a dropped event
		// self-heals without redelivery.
		s.handleAccountUpdated(event)
	case "payout.paid":
		handleErr = s.handlePayoutTerminal(event, envelope.Account, true)
	case "payout.failed", "payout.canceled":
		handleErr = s.handlePayoutTerminal(event, envelope.Account, false)
	case "transfer.reversed":
		handleErr = s.handleTransferFailed(event)
	default:
		// Ignore everything else — we just ack.
	}
	if handleErr != nil {
		http.Error(w, "transient failure — retry", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// handleAccountUpdated mirrors Stripe's view of the connected account into our
// User row. This is what flips a user from "pending" → "ready".
func (s *Controller) handleAccountUpdated(event *billingservice.WebhookEvent) {
	acct, err := s.billing().StripeConnect().AccountUpdatedFromEvent(event)
	if err != nil {
		s.logger.Warn("stripe connect webhook: account.updated parse failed", "error", err)
		return
	}
	user, err := s.billing().Store().GetUserByStripeAccount(acct.ID)
	if err != nil {
		s.logger.Warn("stripe connect webhook: account.updated user lookup failed",
			"stripe_account_id", acct.ID, "error", err)
		return
	}
	status := stripeStatusForAccount(acct)
	if err := s.billing().Store().SetUserStripeAccount(user.AccountID, acct.ID,
		status, acct.Country, acct.DestinationType, acct.DestinationLast4, acct.InstantEligible); err != nil {
		s.logger.Error("stripe connect webhook: persist account state failed", "error", err)
	}
}
