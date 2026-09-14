package billing

import (
	"io"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// StripeWebhook handles POST /v1/billing/stripe/webhook.
func (s *Controller) StripeWebhook(w http.ResponseWriter, r *http.Request) {
	if s.billing() == nil || s.billing().Stripe() == nil {
		http.Error(w, "Stripe not configured", http.StatusServiceUnavailable)
		return
	}

	payload, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "failed to read body", http.StatusBadRequest)
		return
	}

	sigHeader := r.Header.Get("Stripe-Signature")
	event, err := s.billing().Stripe().VerifyWebhookSignature(payload, sigHeader)
	if err != nil {
		s.logger.Error("stripe: webhook signature verification failed", "error", err)
		http.Error(w, "invalid signature", http.StatusBadRequest)
		return
	}

	if event.Type != "checkout.session.completed" {
		w.WriteHeader(http.StatusOK)
		return
	}

	session, err := s.billing().Stripe().ParseCheckoutSession(event)
	if err != nil {
		s.logger.Error("stripe: parse checkout session failed", "error", err)
		http.Error(w, "invalid event data", http.StatusBadRequest)
		return
	}

	billingSessionID := session.Object.Metadata["billing_session_id"]
	consumerKey := session.Object.Metadata["consumer_key"]
	referralCode := session.Object.Metadata["referral_code"]

	if consumerKey == "" {
		s.logger.Error("stripe: webhook missing consumer_key in metadata")
		http.Error(w, "missing metadata", http.StatusBadRequest)
		return
	}

	if billingSessionID != "" {
		bs, err := s.billing().Store().GetBillingSession(billingSessionID)
		if err == nil && bs.Status == "completed" {
			w.WriteHeader(http.StatusOK)
			return
		}
	}

	amountMicroUSD := session.Object.AmountTotal * 10_000

	if err := s.billing().CreditDeposit(consumerKey, amountMicroUSD, store.LedgerStripeDeposit,
		"stripe:"+session.Object.ID); err != nil {
		s.logger.Error("stripe: credit balance failed", "error", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	if billingSessionID != "" {
		// Best-effort: the deposit is already credited above, but a failure here
		// leaves the session marked incomplete (and replayable). Surface it.
		if err := s.billing().Store().CompleteBillingSession(billingSessionID); err != nil {
			s.logger.Error("stripe: failed to mark billing session complete",
				"billing_session_id", billingSessionID, "error", err)
			s.recordMetric("billing.session_complete_failed", nil)
		}
	}
	if referralCode != "" {
		// Best-effort: a failure here means the referrer is not credited for this
		// deposit; never silently swallow it.
		if err := s.billing().Referral().Apply(consumerKey, referralCode); err != nil {
			s.logger.Error("stripe: failed to apply referral credit", "error", err)
			s.recordMetric("billing.referral_apply_failed", nil)
		}
	}

	s.logger.Info("stripe: deposit credited",
		"consumer_key", consumerKey[:min(8, len(consumerKey))]+"...",
		"amount_micro_usd", amountMicroUSD,
	)
	w.WriteHeader(http.StatusOK)
}
