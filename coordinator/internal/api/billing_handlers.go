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
//
// Endpoints that modify account state (referral, pricing, deposits) require
// Privy authentication to prevent spam. API key auth is accepted for
// read-only endpoints and inference.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/store"
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

// --- Solana Deposit (client-side signed) ---

// handleSolanaDeposit handles POST /v1/billing/deposit.
// The user signs a USDC transfer in their frontend wallet, then submits the
// tx signature here. We verify on-chain that:
//  1. The tx contains a USDC transfer TO our coordinator address
//  2. The tx sender matches the authenticated user's wallet
//  3. The tx hasn't been submitted before (double-spend protection)
func (s *Server) handleSolanaDeposit(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "billing not configured"))
		return
	}

	// --- Mock mode: skip on-chain verification, credit directly ---
	if s.billing.MockMode() {
		s.handleMockDeposit(w, r)
		return
	}

	if s.billing.Solana() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "Solana payments not configured"))
		return
	}
	if s.requirePrivyUser(w, r) == nil {
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
		"status":            "deposited",
		"tx_signature":      req.TxSignature,
		"from":              result.From,
		"amount_micro_usd":  result.AmountMicroUSD,
		"amount_usd":        fmt.Sprintf("%.6f", float64(result.AmountMicroUSD)/1_000_000),
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

// MinWithdrawalMicroUSD is the minimum withdrawal amount (1,000,000 micro-USD = $1.00).
const MinWithdrawalMicroUSD = 1_000_000

// handleSolanaWithdraw handles POST /v1/billing/withdraw/solana.
func (s *Server) handleSolanaWithdraw(w http.ResponseWriter, r *http.Request) {
	// Require Privy auth — withdrawals must be tied to an authenticated user.
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}

	if s.billing == nil || s.billing.Solana() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "Solana payments not configured"))
		return
	}

	var req struct {
		WalletAddress string `json:"wallet_address"`
		AmountUSD     string `json:"amount_usd"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	// Auto-populate wallet from account if not provided in request.
	if req.WalletAddress == "" {
		req.WalletAddress = user.SolanaWalletAddress
	}

	if req.WalletAddress == "" || req.AmountUSD == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "wallet_address and amount_usd are required"))
		return
	}

	// Validate destination wallet — must match the user's linked Solana wallet
	// to prevent fund theft (cannot withdraw to someone else's address).
	if user.SolanaWalletAddress != "" && req.WalletAddress != user.SolanaWalletAddress {
		writeJSON(w, http.StatusForbidden, errorResponse("wallet_mismatch",
			"withdrawals must go to your linked Solana wallet"))
		return
	}

	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}

	amountMicroUSD := int64(amountFloat * 1_000_000)

	// Minimum withdrawal check — must be at least $1.00.
	if amountMicroUSD < MinWithdrawalMicroUSD {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			fmt.Sprintf("minimum withdrawal is $%.2f", float64(MinWithdrawalMicroUSD)/1_000_000)))
		return
	}

	// Use the authenticated user's account ID for the debit.
	accountID := user.AccountID

	if err := s.billing.Ledger().Charge(accountID, amountMicroUSD, "withdraw:solana:"+req.WalletAddress); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("insufficient_funds", err.Error()))
		return
	}

	result, err := s.billing.Solana().SendWithdrawal(billing.SolanaWithdrawRequest{
		ToAddress:      req.WalletAddress,
		AmountMicroUSD: amountMicroUSD,
	})
	if err != nil {
		_ = s.billing.Ledger().Deposit(accountID, amountMicroUSD)
		s.logger.Error("solana: withdrawal failed, re-credited", "error", err)
		writeJSON(w, http.StatusBadGateway, errorResponse("withdrawal_error", err.Error()))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":            "withdrawn",
		"chain":             "solana",
		"wallet_address":    req.WalletAddress,
		"amount_usd":        req.AmountUSD,
		"amount_micro_usd":  amountMicroUSD,
		"tx_signature":      result.TxSignature,
		"balance_micro_usd": s.billing.Ledger().Balance(accountID),
	})
}

// --- Referral Handlers ---

func (s *Server) handleReferralRegister(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "referral system not available"))
		return
	}
	if s.requirePrivyUser(w, r) == nil {
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
	if s.requirePrivyUser(w, r) == nil {
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
// Public endpoint — returns platform default prices. Also overlays platform
// DB overrides (set via admin endpoint).
func (s *Server) handleGetPricing(w http.ResponseWriter, r *http.Request) {
	defaults := payments.DefaultPrices()

	type priceEntry struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`  // micro-USD per 1M tokens
		OutputPrice int64  `json:"output_price"` // micro-USD per 1M tokens
		InputUSD    string `json:"input_usd"`
		OutputUSD   string `json:"output_usd"`
	}

	// Start with hardcoded defaults.
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

	// Overlay admin-set platform prices (account_id = "platform").
	platformPrices := s.store.ListModelPrices("platform")
	for _, mp := range platformPrices {
		priceMap[mp.Model] = priceEntry{
			Model:       mp.Model,
			InputPrice:  mp.InputPrice,
			OutputPrice: mp.OutputPrice,
			InputUSD:    fmt.Sprintf("$%.4f", float64(mp.InputPrice)/1_000_000),
			OutputUSD:   fmt.Sprintf("$%.4f", float64(mp.OutputPrice)/1_000_000),
		}
	}

	var prices []priceEntry
	for _, p := range priceMap {
		prices = append(prices, p)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"prices": prices,
	})
}

// handleAdminPricing handles PUT /v1/admin/pricing.
// Sets platform default prices for a model. Requires a Privy account with
// an admin email. These defaults apply to all users who haven't set custom prices.
func (s *Server) handleAdminPricing(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil || !s.isAdmin(user) {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
		return
	}

	var req struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`
		OutputPrice int64  `json:"output_price"`
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
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "input_price and output_price must be positive"))
		return
	}

	// Store under the special "platform" account.
	if err := s.store.SetModelPrice("platform", req.Model, req.InputPrice, req.OutputPrice); err != nil {
		s.logger.Error("admin pricing: set failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to set price"))
		return
	}

	s.logger.Info("admin: platform price updated",
		"model", req.Model,
		"input_price", req.InputPrice,
		"output_price", req.OutputPrice,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "platform_default_updated",
		"model":        req.Model,
		"input_price":  req.InputPrice,
		"output_price": req.OutputPrice,
		"input_usd":    fmt.Sprintf("$%.4f per 1M tokens", float64(req.InputPrice)/1_000_000),
		"output_usd":   fmt.Sprintf("$%.4f per 1M tokens", float64(req.OutputPrice)/1_000_000),
	})
}

// handleSetPricing handles PUT /v1/pricing.
// Providers set custom prices for models they serve. Requires Privy auth.
func (s *Server) handleSetPricing(w http.ResponseWriter, r *http.Request) {
	if s.requirePrivyUser(w, r) == nil {
		return
	}
	var req struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`
		OutputPrice int64  `json:"output_price"`
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
	if s.requirePrivyUser(w, r) == nil {
		return
	}
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

// isAdmin checks if the user has admin privileges (email in admin list).
func (s *Server) isAdmin(user *store.User) bool {
	if user == nil || user.Email == "" || len(s.adminEmails) == 0 {
		return false
	}
	return s.adminEmails[strings.ToLower(user.Email)]
}

// requirePrivyUser checks that the request is authenticated via Privy (not just API key).
// Returns the user or writes a 401 error and returns nil.
func (s *Server) requirePrivyUser(w http.ResponseWriter, r *http.Request) *store.User {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error",
			"this endpoint requires a Privy account — authenticate with a Privy access token"))
		return nil
	}
	return user
}

// --- Admin Model Catalog ---

// handleAdminListModels handles GET /v1/admin/models.
// Returns the full supported model catalog. Requires admin auth.
func (s *Server) handleAdminListModels(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil || !s.isAdmin(user) {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
		return
	}

	models := s.store.ListSupportedModels()
	if models == nil {
		models = []store.SupportedModel{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"models": models})
}

// handleAdminSetModel handles POST /v1/admin/models.
// Adds or updates a model in the catalog. Requires admin auth.
func (s *Server) handleAdminSetModel(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil || !s.isAdmin(user) {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
		return
	}

	var model store.SupportedModel
	if err := json.NewDecoder(r.Body).Decode(&model); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if model.ID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "id is required"))
		return
	}
	if model.DisplayName == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "display_name is required"))
		return
	}

	if err := s.store.SetSupportedModel(&model); err != nil {
		s.logger.Error("admin: set model failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to save model"))
		return
	}

	// Sync the updated catalog to the registry so routing reflects the change.
	s.SyncModelCatalog()

	s.logger.Info("admin: model catalog updated",
		"model_id", model.ID,
		"display_name", model.DisplayName,
		"active", model.Active,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status": "model_saved",
		"model":  model,
	})
}

// handleAdminDeleteModel handles DELETE /v1/admin/models.
// Removes a model from the catalog. Requires admin auth.
func (s *Server) handleAdminDeleteModel(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil || !s.isAdmin(user) {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
		return
	}

	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.ID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "id is required"))
		return
	}

	if err := s.store.DeleteSupportedModel(req.ID); err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
		return
	}

	// Sync the updated catalog to the registry so routing reflects the change.
	s.SyncModelCatalog()

	s.logger.Info("admin: model removed from catalog", "model_id", req.ID)
	writeJSON(w, http.StatusOK, map[string]any{
		"status":   "model_deleted",
		"model_id": req.ID,
	})
}

// handleModelCatalog handles GET /v1/models/catalog.
// Public endpoint — returns active models for providers and the install script.
func (s *Server) handleModelCatalog(w http.ResponseWriter, r *http.Request) {
	allModels := s.store.ListSupportedModels()

	// Optional filter: ?type=text or ?type=transcription
	typeFilter := r.URL.Query().Get("type")

	// Filter to active models only (and by type if specified)
	var active []store.SupportedModel
	for _, m := range allModels {
		if !m.Active {
			continue
		}
		if typeFilter != "" && m.ModelType != typeFilter {
			continue
		}
		active = append(active, m)
	}
	if active == nil {
		active = []store.SupportedModel{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"models": active})
}

// handleMockDeposit handles deposits in mock mode: credits the account
// directly without on-chain verification. For testing only.
func (s *Server) handleMockDeposit(w http.ResponseWriter, r *http.Request) {
	var req struct {
		AmountUSD    float64 `json:"amount_usd"`
		ReferralCode string  `json:"referral_code,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	if req.AmountUSD <= 0 {
		req.AmountUSD = 100.0 // default $100 test credit
	}

	accountID := s.resolveAccountID(r)
	amountMicroUSD := int64(req.AmountUSD * 1_000_000)

	if err := s.billing.CreditDeposit(accountID, amountMicroUSD, store.LedgerDeposit,
		"mock-deposit"); err != nil {
		s.logger.Error("mock deposit: credit failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to credit balance"))
		return
	}

	s.logger.Info("mock deposit credited",
		"account_id", accountID,
		"amount_usd", req.AmountUSD,
		"amount_micro_usd", amountMicroUSD,
	)

	balance := s.billing.Ledger().Balance(accountID)
	writeJSON(w, http.StatusOK, map[string]any{
		"status":            "credited",
		"mock":              true,
		"amount_micro_usd":  amountMicroUSD,
		"amount_usd":        req.AmountUSD,
		"balance_micro_usd": balance,
		"balance_usd":       fmt.Sprintf("%.2f", float64(balance)/1_000_000),
	})
}

// handleNodeEarnings handles GET /v1/provider/node-earnings?provider_key=<key>&limit=50.
// Returns recent per-node earnings history plus lifetime aggregates for the node.
func (s *Server) handleNodeEarnings(w http.ResponseWriter, r *http.Request) {
	providerKey := r.URL.Query().Get("provider_key")
	if providerKey == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "provider_key query parameter is required"))
		return
	}

	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > 1000 {
		limit = 1000
	}

	earnings, err := s.store.GetProviderEarnings(providerKey, limit)
	if err != nil {
		s.logger.Error("get provider earnings failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings"))
		return
	}

	summary, err := s.store.GetProviderEarningsSummary(providerKey)
	if err != nil {
		s.logger.Error("get provider earnings summary failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings summary"))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"provider_key":    providerKey,
		"earnings":        earnings,
		"total_micro_usd": summary.TotalMicroUSD,
		"total_usd":       fmt.Sprintf("%.6f", float64(summary.TotalMicroUSD)/1_000_000),
		"count":           summary.Count,
		"recent_count":    len(earnings),
		"history_limit":   limit,
	})
}

// handleAccountEarnings handles GET /v1/provider/account-earnings?limit=50.
// Returns recent earnings history, lifetime aggregates, and current account balance
// for the authenticated provider account.
func (s *Server) handleAccountEarnings(w http.ResponseWriter, r *http.Request) {
	accountID := s.resolveAccountID(r)

	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > 1000 {
		limit = 1000
	}

	earnings, err := s.store.GetAccountEarnings(accountID, limit)
	if err != nil {
		s.logger.Error("get account earnings failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings"))
		return
	}

	summary, err := s.store.GetAccountEarningsSummary(accountID)
	if err != nil {
		s.logger.Error("get account earnings summary failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings summary"))
		return
	}

	availableBalance := s.store.GetBalance(accountID)

	writeJSON(w, http.StatusOK, map[string]any{
		"account_id":                  accountID,
		"earnings":                    earnings,
		"total_micro_usd":             summary.TotalMicroUSD,
		"total_usd":                   fmt.Sprintf("%.6f", float64(summary.TotalMicroUSD)/1_000_000),
		"count":                       summary.Count,
		"recent_count":                len(earnings),
		"history_limit":               limit,
		"available_balance_micro_usd": availableBalance,
		"available_balance_usd":       fmt.Sprintf("%.6f", float64(availableBalance)/1_000_000),
	})
}
