package api

import (
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// --- Stripe Handlers ---

// handleStripeCreateSession handles POST /v1/billing/stripe/create-session.
func (s *Server) handleStripeCreateSession(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Stripe() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "Stripe payments not configured"))
		return
	}

	var req struct {
		AmountUSD    string `json:"amount_usd"`
		Email        string `json:"email,omitempty"`
		ReferralCode string `json:"referral_code,omitempty"`
	}
	if !decodeJSONBody(w, r, &req) {
		return
	}

	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat < 0.50 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be at least $0.50"))
		return
	}

	amountCents := int64(amountFloat * 100)
	accountID := s.resolveAccountID(r)

	if req.ReferralCode != "" {
		if _, err := s.billing.Store().GetReferrerByCode(req.ReferralCode); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid referral code"))
			return
		}
	}

	sessionID := uuid.New().String()
	amountMicroUSD := payments.USDToMicro(amountFloat)

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
		writeJSON(w, http.StatusBadGateway, errorResponse("stripe_error", "failed to create checkout session"))
		return
	}

	billingSession.ExternalID = stripeResp.SessionID
	if err := s.billing.Store().CreateBillingSession(billingSession); err != nil {
		s.logger.Error("stripe: save billing session failed", "error", err)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"session_id":       sessionID,
		"stripe_session":   stripeResp.SessionID,
		"url":              stripeResp.URL,
		"amount_usd":       req.AmountUSD,
		"amount_micro_usd": amountMicroUSD,
	})
}

// handleStripeWebhook handles POST /v1/billing/stripe/webhook.
func (s *Server) handleStripeWebhook(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Stripe() == nil {
		http.Error(w, "Stripe not configured", http.StatusServiceUnavailable)
		return
	}

	payload, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "failed to read body", http.StatusBadRequest)
		return
	}

	sigHeader := r.Header.Get("Stripe-Signature")
	event, err := s.billing.Stripe().VerifyWebhookSignature(payload, sigHeader)
	if err != nil {
		s.logger.Error("stripe: webhook signature verification failed", "error", err)
		http.Error(w, "invalid signature", http.StatusBadRequest)
		return
	}

	if event.Type != "checkout.session.completed" {
		w.WriteHeader(http.StatusOK)
		return
	}

	session, err := s.billing.Stripe().ParseCheckoutSession(event)
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
		bs, err := s.billing.Store().GetBillingSession(billingSessionID)
		if err == nil && bs.Status == "completed" {
			w.WriteHeader(http.StatusOK)
			return
		}
	}

	amountMicroUSD := session.Object.AmountTotal * 10_000

	if err := s.billing.CreditDeposit(consumerKey, amountMicroUSD, store.LedgerStripeDeposit,
		"stripe:"+session.Object.ID); err != nil {
		s.logger.Error("stripe: credit balance failed", "error", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	if billingSessionID != "" {
		_ = s.billing.Store().CompleteBillingSession(billingSessionID)
	}
	if referralCode != "" {
		_ = s.billing.Referral().Apply(consumerKey, referralCode)
	}

	s.logger.Info("stripe: deposit credited",
		"consumer_key", consumerKey[:min(8, len(consumerKey))]+"...",
		"amount_micro_usd", amountMicroUSD,
	)
	w.WriteHeader(http.StatusOK)
}

// handleStripeSessionStatus handles GET /v1/billing/stripe/session?id=...
func (s *Server) handleStripeSessionStatus(w http.ResponseWriter, r *http.Request) {
	sessionID := r.URL.Query().Get("id")
	if sessionID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "id query parameter required"))
		return
	}

	bs, err := s.billing.Store().GetBillingSession(sessionID)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "billing session not found"))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"session_id":       bs.ID,
		"payment_method":   bs.PaymentMethod,
		"amount_micro_usd": bs.AmountMicroUSD,
		"status":           bs.Status,
		"created_at":       bs.CreatedAt,
		"completed_at":     bs.CompletedAt,
	})
}

// handleWalletBalance handles GET /v1/billing/wallet/balance.
func (s *Server) handleWalletBalance(w http.ResponseWriter, r *http.Request) {
	accountID := s.resolveAccountID(r)

	resp := map[string]any{
		"credit_balance_micro_usd": s.billing.Ledger().Balance(accountID),
	}

	writeJSON(w, http.StatusOK, resp)
}

// --- Payment Methods ---

func (s *Server) handleBillingMethods(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil {
		writeJSON(w, http.StatusOK, map[string]any{"methods": []any{}})
		return
	}
	methods := s.billing.SupportedMethods()
	resp := map[string]any{"methods": methods}
	if s.billing.Referral() != nil {
		resp["referral"] = map[string]any{
			"enabled":       true,
			"share_percent": s.billing.Referral().SharePercent(),
		}
	}
	writeJSON(w, http.StatusOK, resp)
}
