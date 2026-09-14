package billing

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// StripeCreateSession handles POST /v1/billing/stripe/create-session.
func (s *Controller) StripeCreateSession(w http.ResponseWriter, r *http.Request) {
	if s.billing() == nil || s.billing().Stripe() == nil {
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("billing_error", "Stripe payments not configured"))
		return
	}

	var req struct {
		AmountUSD    string `json:"amount_usd"`
		Email        string `json:"email,omitempty"`
		ReferralCode string `json:"referral_code,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat < 0.50 {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "amount_usd must be at least $0.50"))
		return
	}

	amountCents := int64(amountFloat * 100)
	accountID := requestauth.ResolveAccountID(r)

	if req.ReferralCode != "" {
		if _, err := s.billing().Store().GetReferrerByCode(req.ReferralCode); err != nil {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid referral code"))
			return
		}
	}

	sessionID := uuid.New().String()
	amountMicroUSD := int64(amountFloat * 1_000_000)

	billingSession := &store.BillingSession{
		ID:             sessionID,
		AccountID:      accountID,
		PaymentMethod:  "stripe",
		AmountMicroUSD: amountMicroUSD,
		Status:         "pending",
		ReferralCode:   req.ReferralCode,
		CreatedAt:      time.Now(),
	}

	stripeResp, err := s.billing().Stripe().CreateCheckoutSession(billingservice.CheckoutSessionRequest{
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
		httpresponse.WriteJSON(w, http.StatusBadGateway, httpresponse.ErrorBody("stripe_error", "failed to create checkout session"))
		return
	}

	billingSession.ExternalID = stripeResp.SessionID
	if err := s.billing().Store().CreateBillingSession(billingSession); err != nil {
		s.logger.Error("stripe: save billing session failed", "error", err)
	}

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"session_id":       sessionID,
		"stripe_session":   stripeResp.SessionID,
		"url":              stripeResp.URL,
		"amount_usd":       req.AmountUSD,
		"amount_micro_usd": amountMicroUSD,
	})
}

// StripeSessionStatus handles GET /v1/billing/stripe/session?id=...
func (s *Controller) StripeSessionStatus(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("id")
	if sessionID == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "id query parameter required"))
		return
	}

	bs, err := s.billing().Store().GetBillingSession(sessionID)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "billing session not found"))
		return
	}

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"session_id":       bs.ID,
		"payment_method":   bs.PaymentMethod,
		"amount_micro_usd": bs.AmountMicroUSD,
		"status":           bs.Status,
		"created_at":       bs.CreatedAt,
		"completed_at":     bs.CompletedAt,
	})
}
