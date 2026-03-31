package api

// Billing API handlers for Stripe, Solana payments and referral system.
//
// These handlers extend the existing payment endpoints with Solana USDC
// support and a referral code system. All payment methods credit the same
// internal micro-USD ledger.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/dginf/coordinator/internal/billing"
	"github.com/dginf/coordinator/internal/store"
	"github.com/google/uuid"
)

// --- Stripe Handlers ---

// handleStripeCreateSession handles POST /v1/billing/stripe/create-session.
// Creates a Stripe Checkout Session and returns the payment URL.
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat < 0.50 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be at least $0.50"))
		return
	}

	amountCents := int64(amountFloat * 100)
	consumerKey := consumerKeyFromContext(r.Context())

	// Validate referral code if provided
	if req.ReferralCode != "" {
		_, err := s.billing.Store().GetReferrerByCode(req.ReferralCode)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid referral code"))
			return
		}
	}

	// Create billing session record
	sessionID := uuid.New().String()
	amountMicroUSD := int64(amountFloat * 1_000_000)

	billingSession := &store.BillingSession{
		ID:             sessionID,
		AccountID:      consumerKey,
		PaymentMethod:  "stripe",
		AmountMicroUSD: amountMicroUSD,
		Status:         "pending",
		ReferralCode:   req.ReferralCode,
		CreatedAt:      time.Now(),
	}

	// Create Stripe Checkout Session
	stripeResp, err := s.billing.Stripe().CreateCheckoutSession(billing.CheckoutSessionRequest{
		AmountCents:   amountCents,
		Currency:      "usd",
		CustomerEmail: req.Email,
		Metadata: map[string]string{
			"billing_session_id": sessionID,
			"consumer_key":      consumerKey,
			"referral_code":     req.ReferralCode,
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
		"session_id":      sessionID,
		"stripe_session":  stripeResp.SessionID,
		"url":             stripeResp.URL,
		"amount_usd":      req.AmountUSD,
		"amount_micro_usd": amountMicroUSD,
	})
}

// handleStripeWebhook handles POST /v1/billing/stripe/webhook.
// Verifies the Stripe signature and credits the consumer's balance.
// No API key auth — Stripe sends this directly.
func (s *Server) handleStripeWebhook(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Stripe() == nil {
		http.Error(w, "Stripe not configured", http.StatusServiceUnavailable)
		return
	}

	// Read the raw body for signature verification
	payload, err := io.ReadAll(io.LimitReader(r.Body, 1<<20)) // 1MB max
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

	// Only handle checkout.session.completed
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

	// Extract metadata
	billingSessionID := session.Object.Metadata["billing_session_id"]
	consumerKey := session.Object.Metadata["consumer_key"]
	referralCode := session.Object.Metadata["referral_code"]

	if consumerKey == "" {
		s.logger.Error("stripe: webhook missing consumer_key in metadata")
		http.Error(w, "missing metadata", http.StatusBadRequest)
		return
	}

	// Prevent double-crediting via billing session
	if billingSessionID != "" {
		bs, err := s.billing.Store().GetBillingSession(billingSessionID)
		if err == nil && bs.Status == "completed" {
			s.logger.Warn("stripe: billing session already completed", "session_id", billingSessionID)
			w.WriteHeader(http.StatusOK)
			return
		}
	}

	// Convert cents to micro-USD (1 cent = 10,000 micro-USD)
	amountMicroUSD := session.Object.AmountTotal * 10_000

	// Credit the consumer's balance
	if err := s.billing.CreditDeposit(consumerKey, amountMicroUSD, store.LedgerStripeDeposit,
		"stripe:"+session.Object.ID); err != nil {
		s.logger.Error("stripe: credit balance failed", "error", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// Mark billing session as completed
	if billingSessionID != "" {
		_ = s.billing.Store().CompleteBillingSession(billingSessionID)
	}

	// Apply referral code if present and not already applied
	if referralCode != "" {
		_ = s.billing.Referral().Apply(consumerKey, referralCode)
	}

	s.logger.Info("stripe: deposit credited",
		"consumer_key", consumerKey[:min(8, len(consumerKey))]+"...",
		"amount_micro_usd", amountMicroUSD,
		"stripe_session", session.Object.ID,
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
		"session_id":      bs.ID,
		"payment_method":  bs.PaymentMethod,
		"amount_micro_usd": bs.AmountMicroUSD,
		"status":          bs.Status,
		"created_at":      bs.CreatedAt,
		"completed_at":    bs.CompletedAt,
	})
}

// --- Solana Deposit/Withdraw Handlers ---

// handleSolanaDeposit handles POST /v1/billing/deposit/solana.
// Verifies a Solana USDC-SPL transfer and credits the consumer's balance.
func (s *Server) handleSolanaDeposit(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TxSignature  string `json:"tx_signature"`
		ReferralCode string `json:"referral_code,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	if req.TxSignature == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "tx_signature is required"))
		return
	}

	if s.billing == nil || s.billing.Solana() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "Solana payments not configured"))
		return
	}

	// Check for double-crediting
	if s.billing.CheckProcessedTx(req.TxSignature) {
		writeJSON(w, http.StatusConflict, errorResponse("duplicate_deposit", "tx_signature has already been processed"))
		return
	}

	consumerKey := consumerKeyFromContext(r.Context())

	// Verify on-chain
	result, err := s.billing.Solana().VerifyDeposit(req.TxSignature)
	if err != nil {
		s.logger.Error("solana: deposit verification failed", "tx_sig", req.TxSignature, "error", err)
		writeJSON(w, http.StatusBadRequest, errorResponse("verification_failed", err.Error()))
		return
	}

	// Mark as processed
	s.billing.MarkProcessedTx(req.TxSignature)

	// Create billing session
	sessionID := uuid.New().String()
	_ = s.billing.Store().CreateBillingSession(&store.BillingSession{
		ID:             sessionID,
		AccountID:      consumerKey,
		PaymentMethod:  "solana",
		Chain:          "solana",
		AmountMicroUSD: result.AmountMicroUSD,
		ExternalID:     req.TxSignature,
		Status:         "completed",
		ReferralCode:   req.ReferralCode,
		CreatedAt:      time.Now(),
	})

	// Credit balance
	if err := s.billing.CreditDeposit(consumerKey, result.AmountMicroUSD, store.LedgerDeposit,
		"solana:"+req.TxSignature); err != nil {
		s.logger.Error("solana: credit balance failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to credit balance"))
		return
	}

	// Apply referral code if present
	if req.ReferralCode != "" {
		_ = s.billing.Referral().Apply(consumerKey, req.ReferralCode)
	}

	s.logger.Info("solana: deposit credited",
		"consumer_key", consumerKey[:min(8, len(consumerKey))]+"...",
		"tx_sig", req.TxSignature,
		"amount_micro_usd", result.AmountMicroUSD,
		"from", result.From,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":          "deposited",
		"chain":           "solana",
		"tx_signature":    req.TxSignature,
		"from":            result.From,
		"amount_micro_usd": result.AmountMicroUSD,
		"amount_usd":      fmt.Sprintf("%.6f", float64(result.AmountMicroUSD)/1_000_000),
		"balance_micro_usd": s.billing.Ledger().Balance(consumerKey),
	})
}

// handleSolanaWithdraw handles POST /v1/billing/withdraw/solana.
func (s *Server) handleSolanaWithdraw(w http.ResponseWriter, r *http.Request) {
	var req struct {
		WalletAddress string `json:"wallet_address"`
		AmountUSD     string `json:"amount_usd"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	if req.WalletAddress == "" || req.AmountUSD == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "wallet_address and amount_usd are required"))
		return
	}

	if s.billing == nil || s.billing.Solana() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "Solana payments not configured"))
		return
	}

	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}

	amountMicroUSD := int64(amountFloat * 1_000_000)
	consumerKey := consumerKeyFromContext(r.Context())

	// Debit balance
	if err := s.billing.Ledger().Charge(consumerKey, amountMicroUSD, "withdraw:solana:"+req.WalletAddress); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("insufficient_funds", err.Error()))
		return
	}

	// Send on-chain
	result, err := s.billing.Solana().SendWithdrawal(billing.SolanaWithdrawRequest{
		ToAddress:      req.WalletAddress,
		AmountMicroUSD: amountMicroUSD,
	}, s.settlementURL)
	if err != nil {
		// Re-credit on failure
		_ = s.billing.Ledger().Deposit(consumerKey, amountMicroUSD)
		s.logger.Error("solana: withdrawal failed, re-credited", "error", err)
		writeJSON(w, http.StatusBadGateway, errorResponse("settlement_error", err.Error()))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":          "withdrawn",
		"chain":           "solana",
		"wallet_address":  req.WalletAddress,
		"amount_usd":      req.AmountUSD,
		"amount_micro_usd": amountMicroUSD,
		"tx_signature":    result.TxSignature,
		"balance_micro_usd": s.billing.Ledger().Balance(consumerKey),
	})
}

// --- Deposit Addresses ---

// handleDepositAddresses handles GET /v1/billing/deposit/addresses.
// Returns all configured deposit addresses for crypto payments.
func (s *Server) handleDepositAddresses(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil {
		writeJSON(w, http.StatusOK, map[string]any{"evm": map[string]string{}, "solana": ""})
		return
	}

	addrs := s.billing.DepositAddresses()
	writeJSON(w, http.StatusOK, addrs)
}

// --- Referral Handlers ---

// handleReferralRegister handles POST /v1/referral/register.
// Registers the consumer as a referrer and returns their unique referral code.
func (s *Server) handleReferralRegister(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "referral system not available"))
		return
	}

	consumerKey := consumerKeyFromContext(r.Context())
	referrer, err := s.billing.Referral().Register(consumerKey)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("referral_error", err.Error()))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"code":          referrer.Code,
		"account_id":    referrer.AccountID[:min(8, len(referrer.AccountID))] + "...",
		"share_percent": s.billing.Referral().SharePercent(),
		"message":       fmt.Sprintf("Share your code %s — you earn %d%% of the platform fee on every inference by referred users.", referrer.Code, s.billing.Referral().SharePercent()),
	})
}

// handleReferralApply handles POST /v1/referral/apply.
// Links the consumer's account to a referral code.
func (s *Server) handleReferralApply(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "referral system not available"))
		return
	}

	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	if req.Code == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "code is required"))
		return
	}

	consumerKey := consumerKeyFromContext(r.Context())
	if err := s.billing.Referral().Apply(consumerKey, req.Code); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("referral_error", err.Error()))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "applied",
		"code":    req.Code,
		"message": "Referral code applied successfully.",
	})
}

// handleReferralStats handles GET /v1/referral/stats.
// Returns referral statistics and earnings for the authenticated user.
func (s *Server) handleReferralStats(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "referral system not available"))
		return
	}

	consumerKey := consumerKeyFromContext(r.Context())
	stats, err := s.billing.Referral().Stats(consumerKey)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("referral_error", err.Error()))
		return
	}

	writeJSON(w, http.StatusOK, stats)
}

// handleReferralInfo handles GET /v1/referral/info.
// Returns the consumer's referral code if they are a registered referrer.
func (s *Server) handleReferralInfo(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "referral system not available"))
		return
	}

	consumerKey := consumerKeyFromContext(r.Context())
	referrer, err := s.billing.Store().GetReferrerByAccount(consumerKey)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("referral_error", "not a registered referrer — use POST /v1/referral/register"))
		return
	}

	// Also check if this account was referred by someone
	referredBy, _ := s.billing.Store().GetReferrerForAccount(consumerKey)

	writeJSON(w, http.StatusOK, map[string]any{
		"code":          referrer.Code,
		"share_percent": s.billing.Referral().SharePercent(),
		"referred_by":   referredBy,
	})
}

// --- Payment Methods ---

// handleBillingMethods handles GET /v1/billing/methods.
// Returns all supported payment methods and their configuration.
func (s *Server) handleBillingMethods(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil {
		writeJSON(w, http.StatusOK, map[string]any{"methods": []any{}})
		return
	}

	methods := s.billing.SupportedMethods()
	writeJSON(w, http.StatusOK, map[string]any{
		"methods": methods,
		"referral": map[string]any{
			"enabled":       true,
			"share_percent": s.billing.Referral().SharePercent(),
			"description":   "Earn a share of platform fees for every user you refer.",
		},
	})
}
