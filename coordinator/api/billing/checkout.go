package billing

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// handleStripeCreateSession handles POST /v1/billing/stripe/create-session.
func (s *Owner) HandleStripeCreateSession(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Stripe() == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "Stripe payments not configured"))
		return
	}

	var req struct {
		AmountUSD    string `json:"amount_usd"`
		Email        string `json:"email,omitempty"`
		ReferralCode string `json:"referral_code,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	amountCents, err := checkoutUSDCents(req.AmountUSD)
	if err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "amount_usd must be at least $0.50 with at most two decimals"))
		return
	}

	accountID := access.ResolveAccountID(r)

	if req.ReferralCode != "" {
		if _, err := s.billing.Store().GetReferrerByCode(req.ReferralCode); err != nil {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid referral code"))
			return
		}
	}

	sessionID := uuid.New().String()
	amountMicroUSD := amountCents * 10_000

	billingSession := &store.BillingSession{
		ID:             sessionID,
		AccountID:      accountID,
		PaymentMethod:  "stripe",
		AmountMicroUSD: amountMicroUSD,
		Status:         "pending",
		ReferralCode:   req.ReferralCode,
		CreatedAt:      time.Now(),
	}

	stripeResp, err := s.billing.Stripe().CreateCheckoutSession(billing.CheckoutSessionRequest{
		AmountCents:   amountCents,
		Currency:      "usd",
		CustomerEmail: req.Email,
		Metadata: map[string]string{
			"app":                "darkbloom",
			"platform":           "eigeninference",
			"purchase_type":      "inference_credits",
			"source":             "coordinator",
			"coordinator_host":   r.Host,
			"billing_session_id": sessionID,
			"consumer_key":       accountID,
			"referral_code":      req.ReferralCode,
		},
	})
	if err != nil {
		s.logger.Error("stripe: create checkout session failed", "error", err)
		httpx.WriteJSON(w, http.StatusBadGateway, httpx.ErrorResponse("stripe_error", "failed to create checkout session"))
		return
	}

	billingSession.ExternalID = stripeResp.SessionID
	if err := s.billing.Store().CreateBillingSession(billingSession); err != nil {
		if errors.Is(err, store.ErrErasureConflict) {
			httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("account_deleted", "Checkout is unavailable for a deleted account"))
			return
		}
		s.logger.Error("stripe: save billing session failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("billing_error", "Could not save Checkout. Please try again."))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"session_id":       sessionID,
		"stripe_session":   stripeResp.SessionID,
		"url":              stripeResp.URL,
		"amount_usd":       req.AmountUSD,
		"amount_micro_usd": amountMicroUSD,
	})
}

// handleStripeSessionStatus handles GET /v1/billing/stripe/session?id=...
func (s *Owner) HandleStripeSessionStatus(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("id")
	if sessionID == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "id query parameter required"))
		return
	}

	bs, err := s.billing.Store().GetBillingSession(sessionID)
	if err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "billing session not found"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"session_id":       bs.ID,
		"payment_method":   bs.PaymentMethod,
		"amount_micro_usd": bs.AmountMicroUSD,
		"status":           bs.Status,
		"created_at":       bs.CreatedAt,
		"completed_at":     bs.CompletedAt,
	})
}
