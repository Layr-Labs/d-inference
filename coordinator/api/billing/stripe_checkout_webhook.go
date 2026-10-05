package billing

import (
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/internal/billing/amount"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Both accounts can deliver already-created Checkout sessions during migration.
// The database session and ledger reference, not the signing key, own the credit.
func (s *Owner) HandleStripeWebhook(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Stripe() == nil {
		http.Error(w, "Stripe not configured", http.StatusServiceUnavailable)
		return
	}
	payload, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		http.Error(w, "Invalid body", http.StatusBadRequest)
		return
	}
	processor := s.billing.Stripe()
	event, err := processor.VerifyWebhookSignature(payload, r.Header.Get("Stripe-Signature"))
	if err != nil && s.billing.StripeLegacyWebhookSecret() != "" {
		legacy := billing.NewStripeProcessor("", s.billing.StripeLegacyWebhookSecret(), "", "", s.logger)
		event, err = legacy.VerifyWebhookSignature(payload, r.Header.Get("Stripe-Signature"))
	}
	if err != nil {
		http.Error(w, "Invalid signature", http.StatusBadRequest)
		return
	}
	if event.Type != "checkout.session.completed" {
		w.WriteHeader(http.StatusOK)
		return
	}
	session, err := processor.ParseCheckoutSession(event)
	if err != nil {
		http.Error(w, "Invalid Checkout event", http.StatusBadRequest)
		return
	}
	obj := session.Object
	// Other applications may share the old account. Never credit them using
	// arbitrary metadata or accept another currency as USD.
	if app := obj.Metadata["app"]; app != "" && app != "darkbloom" {
		w.WriteHeader(http.StatusOK)
		return
	}
	id, account := obj.Metadata["billing_session_id"], obj.Metadata["consumer_key"]
	if id == "" || account == "" || obj.Currency != "usd" || obj.AmountTotal <= 0 || obj.AmountTotal > math.MaxInt64/10_000 {
		http.Error(w, "Invalid Checkout metadata or amount", http.StatusBadRequest)
		return
	}
	repo, ok := store.As[store.StripeSettlementStore](s.billing.Store())
	if !ok {
		http.Error(w, "Settlement unavailable", http.StatusServiceUnavailable)
		return
	}
	_, err = repo.CompleteStripeCheckout(id, obj.ID, account, obj.AmountTotal*10_000)
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, store.ErrPayoutConflict) {
			status = http.StatusBadRequest
		}
		s.ddIncr("billing.session_complete_failed", nil)
		s.logger.Error("stripe Checkout settlement failed", "billing_session_id", id, "error", err)
		http.Error(w, "Checkout settlement not confirmed", status)
		return
	}
	// Legacy checkout attribution affects future inference, not the deposit.
	// Referral.Apply is idempotent; retries recover without re-crediting payment.
	if code := obj.Metadata["referral_code"]; code != "" {
		if err := s.billing.Referral().Apply(account, code); err != nil {
			if errors.Is(err, billing.ErrInvalidReferral) || errors.Is(err, store.ErrReferralConflict) {
				// The payment is settled. A permanent, inapplicable referral
				// cannot improve on retry and must never change attribution.
				w.WriteHeader(http.StatusOK)
				return
			}
			s.ddIncr("billing.referral_apply_failed", nil)
			s.logger.Error("stripe referral attribution failed", "billing_session_id", id, "error", err)
			http.Error(w, "Referral attribution not confirmed", http.StatusInternalServerError)
			return
		}
	}
	w.WriteHeader(http.StatusOK)
}

func checkoutUSDCents(raw string) (int64, error) {
	raw = strings.TrimSpace(raw)
	if !amount.USDPattern.MatchString(raw) {
		return 0, fmt.Errorf("invalid USD amount")
	}
	parts := strings.SplitN(raw, ".", 2)
	whole, _ := strconv.ParseInt(parts[0], 10, 64)
	var fraction int64
	if len(parts) == 2 {
		fraction, _ = strconv.ParseInt((parts[1] + "0")[:2], 10, 64)
	}
	cents := whole*100 + fraction
	if cents < 50 || cents > 99_999_999 {
		return 0, fmt.Errorf("invalid Checkout amount")
	}
	return cents, nil
}
