package api

// Billing API handlers for Stripe, Solana payments and referral system.
//
// Consumer payment flow (Privy auth + client-side Solana signing):
//   1. User authenticates via Privy JWT → we know their wallet address
//   2. User signs a USDC transfer to coordinator address in the frontend
//   3. User submits tx signature to POST /v1/billing/deposit
//   4. Backend verifies on-chain that the tx came FROM the user's wallet
//   5. Credits internal balance
//
// The user controls their own keys. We only verify what happened on-chain.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/dginf/coordinator/internal/auth"
	"github.com/dginf/coordinator/internal/billing"
	"github.com/dginf/coordinator/internal/payments"
	"github.com/dginf/coordinator/internal/store"
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
	accountID := s.resolveAccountID(r)

	if req.ReferralCode != "" {
		if _, err := s.billing.Store().GetReferrerByCode(req.ReferralCode); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid referral code"))
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

	stripeResp, err := s.billing.Stripe().CreateCheckoutSession(billing.CheckoutSessionRequest{
		AmountCents:   amountCents,
		Currency:      "usd",
		CustomerEmail: req.Email,
		Metadata: map[string]string{
			"billing_session_id": sessionID,
			"consumer_key":      accountID,
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

// --- Solana Deposit (client-side signed) ---

// handleSolanaDeposit handles POST /v1/billing/deposit.
// The user signs a USDC transfer in their frontend wallet, then submits the
// tx signature here. We verify on-chain that:
//   1. The tx contains a USDC transfer TO our coordinator address
//   2. The tx sender matches the authenticated user's wallet
//   3. The tx hasn't been submitted before (double-spend protection)
func (s *Server) handleSolanaDeposit(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Solana() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "Solana payments not configured"))
		return
	}

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

	// Double-spend check (DB-backed, survives restarts).
	if s.billing.IsExternalIDProcessed(req.TxSignature) {
		writeJSON(w, http.StatusConflict, errorResponse("duplicate_deposit", "this transaction has already been credited"))
		return
	}

	// Verify the on-chain transaction.
	result, err := s.billing.Solana().VerifyDeposit(req.TxSignature)
	if err != nil {
		s.logger.Error("deposit: verification failed", "tx_sig", req.TxSignature, "error", err)
		writeJSON(w, http.StatusBadRequest, errorResponse("verification_failed", err.Error()))
		return
	}

	// Auth binding: verify the sender matches the authenticated user's wallet.
	accountID := s.resolveAccountID(r)
	user := auth.UserFromContext(r.Context())
	if user != nil && user.SolanaWalletAddress != "" {
		if result.From != user.SolanaWalletAddress {
			s.logger.Warn("deposit: sender mismatch",
				"expected", user.SolanaWalletAddress,
				"got", result.From,
				"account", accountID[:min(8, len(accountID))]+"...",
			)
			writeJSON(w, http.StatusForbidden, errorResponse("sender_mismatch",
				"transaction sender does not match your authenticated wallet"))
			return
		}
	}

	// Create billing session (marks external_id as processed).
	sessionID := uuid.New().String()
	if err := s.billing.Store().CreateBillingSession(&store.BillingSession{
		ID:             sessionID,
		AccountID:      accountID,
		PaymentMethod:  "solana",
		Chain:          "solana",
		AmountMicroUSD: result.AmountMicroUSD,
		ExternalID:     req.TxSignature,
		Status:         "completed",
		ReferralCode:   req.ReferralCode,
		CreatedAt:      time.Now(),
	}); err != nil {
		writeJSON(w, http.StatusConflict, errorResponse("duplicate_deposit", "this transaction has already been credited"))
		return
	}

	// Credit balance.
	if err := s.billing.CreditDeposit(accountID, result.AmountMicroUSD, store.LedgerDeposit,
		"solana:"+req.TxSignature); err != nil {
		s.logger.Error("deposit: credit failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to credit balance"))
		return
	}

	if req.ReferralCode != "" {
		_ = s.billing.Referral().Apply(accountID, req.ReferralCode)
	}

	s.logger.Info("deposit: credited",
		"account", accountID[:min(8, len(accountID))]+"...",
		"tx_sig", req.TxSignature,
		"amount_micro_usd", result.AmountMicroUSD,
		"from", result.From,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":           "deposited",
		"tx_signature":     req.TxSignature,
		"from":             result.From,
		"amount_micro_usd": result.AmountMicroUSD,
		"amount_usd":       fmt.Sprintf("%.6f", float64(result.AmountMicroUSD)/1_000_000),
		"balance_micro_usd": s.billing.Ledger().Balance(accountID),
	})
}

// handleWalletBalance handles GET /v1/billing/wallet/balance.
func (s *Server) handleWalletBalance(w http.ResponseWriter, r *http.Request) {
	accountID := s.resolveAccountID(r)

	resp := map[string]any{
		"credit_balance_micro_usd": s.billing.Ledger().Balance(accountID),
	}

	if user := auth.UserFromContext(r.Context()); user != nil && user.SolanaWalletAddress != "" {
		resp["wallet_address"] = user.SolanaWalletAddress

		if s.billing != nil && s.billing.Solana() != nil {
			balance, err := s.billing.Solana().GetTokenBalance(user.SolanaWalletAddress)
			if err == nil {
				resp["wallet_usdc_balance"] = balance
				resp["wallet_usdc_usd"] = fmt.Sprintf("%.6f", float64(balance)/1_000_000)
			}
		}
	}

	// Also return the coordinator address so the frontend knows where to send USDC.
	if s.billing != nil && s.billing.CoordinatorAddress() != "" {
		resp["coordinator_address"] = s.billing.CoordinatorAddress()
	}

	writeJSON(w, http.StatusOK, resp)
}

// --- Withdraw ---

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
	accountID := s.resolveAccountID(r)

	if err := s.billing.Ledger().Charge(accountID, amountMicroUSD, "withdraw:solana:"+req.WalletAddress); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("insufficient_funds", err.Error()))
		return
	}

	result, err := s.billing.Solana().SendWithdrawal(billing.SolanaWithdrawRequest{
		ToAddress:      req.WalletAddress,
		AmountMicroUSD: amountMicroUSD,
	}, s.settlementURL)
	if err != nil {
		_ = s.billing.Ledger().Deposit(accountID, amountMicroUSD)
		s.logger.Error("solana: withdrawal failed, re-credited", "error", err)
		writeJSON(w, http.StatusBadGateway, errorResponse("settlement_error", err.Error()))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":           "withdrawn",
		"chain":            "solana",
		"wallet_address":   req.WalletAddress,
		"amount_usd":       req.AmountUSD,
		"amount_micro_usd": amountMicroUSD,
		"tx_signature":     result.TxSignature,
		"balance_micro_usd": s.billing.Ledger().Balance(accountID),
	})
}

// --- Referral Handlers ---

func (s *Server) handleReferralRegister(w http.ResponseWriter, r *http.Request) {
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
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "code is required — choose your own referral code (3-20 chars, alphanumeric)"))
		return
	}

	accountID := s.resolveAccountID(r)
	referrer, err := s.billing.Referral().Register(accountID, req.Code)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("referral_error", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"code":          referrer.Code,
		"share_percent": s.billing.Referral().SharePercent(),
		"message":       fmt.Sprintf("Share your code %s — you earn %d%% of the platform fee on every inference by referred users.", referrer.Code, s.billing.Referral().SharePercent()),
	})
}

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
	accountID := s.resolveAccountID(r)
	if err := s.billing.Referral().Apply(accountID, req.Code); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("referral_error", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "applied",
		"code":    req.Code,
		"message": "Referral code applied successfully.",
	})
}

func (s *Server) handleReferralStats(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "referral system not available"))
		return
	}
	accountID := s.resolveAccountID(r)
	stats, err := s.billing.Referral().Stats(accountID)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("referral_error", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, stats)
}

func (s *Server) handleReferralInfo(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "referral system not available"))
		return
	}
	accountID := s.resolveAccountID(r)
	referrer, err := s.billing.Store().GetReferrerByAccount(accountID)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("referral_error", "not a registered referrer — use POST /v1/referral/register"))
		return
	}
	referredBy, _ := s.billing.Store().GetReferrerForAccount(accountID)
	writeJSON(w, http.StatusOK, map[string]any{
		"code":          referrer.Code,
		"share_percent": s.billing.Referral().SharePercent(),
		"referred_by":   referredBy,
	})
}

// --- Pricing ---

// handleGetPricing handles GET /v1/pricing.
// Returns platform default prices plus any custom overrides for the authenticated user.
func (s *Server) handleGetPricing(w http.ResponseWriter, r *http.Request) {
	defaults := payments.DefaultPrices()

	type priceEntry struct {
		Model       string  `json:"model"`
		InputPrice  int64   `json:"input_price"`  // micro-USD per 1M tokens
		OutputPrice int64   `json:"output_price"` // micro-USD per 1M tokens
		InputUSD    string  `json:"input_usd"`    // human-readable
		OutputUSD   string  `json:"output_usd"`
		Custom      bool    `json:"custom"`
	}

	// Start with defaults.
	priceMap := make(map[string]priceEntry)
	for model, prices := range defaults {
		priceMap[model] = priceEntry{
			Model:       model,
			InputPrice:  prices[0],
			OutputPrice: prices[1],
			InputUSD:    fmt.Sprintf("$%.4f", float64(prices[0])/1_000_000),
			OutputUSD:   fmt.Sprintf("$%.4f", float64(prices[1])/1_000_000),
		}
	}

	// Overlay custom prices if authenticated.
	accountID := s.resolveAccountID(r)
	if accountID != "" {
		customs := s.store.ListModelPrices(accountID)
		for _, mp := range customs {
			priceMap[mp.Model] = priceEntry{
				Model:       mp.Model,
				InputPrice:  mp.InputPrice,
				OutputPrice: mp.OutputPrice,
				InputUSD:    fmt.Sprintf("$%.4f", float64(mp.InputPrice)/1_000_000),
				OutputUSD:   fmt.Sprintf("$%.4f", float64(mp.OutputPrice)/1_000_000),
				Custom:      true,
			}
		}
	}

	// Convert to sorted list.
	var prices []priceEntry
	for _, p := range priceMap {
		prices = append(prices, p)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"prices": prices,
		"note":   "Prices are in micro-USD per 1M tokens. Use PUT /v1/pricing to set custom prices.",
	})
}

// handleSetPricing handles PUT /v1/pricing.
// Sets a custom price override for a model on the authenticated user's account.
func (s *Server) handleSetPricing(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`  // micro-USD per 1M tokens
		OutputPrice int64  `json:"output_price"` // micro-USD per 1M tokens
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required"))
		return
	}
	if req.InputPrice <= 0 || req.OutputPrice <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "input_price and output_price must be positive (micro-USD per 1M tokens)"))
		return
	}

	accountID := s.resolveAccountID(r)
	if err := s.store.SetModelPrice(accountID, req.Model, req.InputPrice, req.OutputPrice); err != nil {
		s.logger.Error("pricing: set failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to set price"))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "updated",
		"model":        req.Model,
		"input_price":  req.InputPrice,
		"output_price": req.OutputPrice,
		"input_usd":    fmt.Sprintf("$%.4f per 1M tokens", float64(req.InputPrice)/1_000_000),
		"output_usd":   fmt.Sprintf("$%.4f per 1M tokens", float64(req.OutputPrice)/1_000_000),
	})
}

// handleDeletePricing handles DELETE /v1/pricing.
// Removes a custom price override, reverting to platform defaults.
func (s *Server) handleDeletePricing(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Model string `json:"model"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required"))
		return
	}

	accountID := s.resolveAccountID(r)
	if err := s.store.DeleteModelPrice(accountID, req.Model); err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status": "deleted",
		"model":  req.Model,
	})
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
	if s.billing.CoordinatorAddress() != "" {
		resp["coordinator_address"] = s.billing.CoordinatorAddress()
	}
	writeJSON(w, http.StatusOK, resp)
}

// resolveAccountID returns the internal account ID for the current request.
// Prefers the Privy user's account ID, falls back to API key.
func (s *Server) resolveAccountID(r *http.Request) string {
	if user := auth.UserFromContext(r.Context()); user != nil {
		return user.AccountID
	}
	return consumerKeyFromContext(r.Context())
}
