package api

// Billing API handlers for Stripe payments and referral system.
//
// Consumer payment flow (Stripe Checkout):
//   1. User authenticates via Privy JWT
//   2. User creates a Stripe Checkout session
//   3. Stripe webhook confirms payment and credits internal balance
//
// Provider payouts use Stripe Connect Express (bank/card withdrawals).
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

	"github.com/eigeninference/d-inference/coordinator/auth"
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
	type priceEntry struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`  // micro-USD per 1M tokens
		OutputPrice int64  `json:"output_price"` // micro-USD per 1M tokens
		InputUSD    string `json:"input_usd"`
		OutputUSD   string `json:"output_usd"`
	}

	// All model prices come from the database (set via PUT /v1/admin/pricing).
	platformPrices := s.store.ListModelPrices("platform")
	prices := make([]priceEntry, 0, len(platformPrices))
	for _, mp := range platformPrices {
		prices = append(prices, priceEntry{
			Model:       mp.Model,
			InputPrice:  mp.InputPrice,
			OutputPrice: mp.OutputPrice,
			InputUSD:    fmt.Sprintf("$%.4f", float64(mp.InputPrice)/1_000_000),
			OutputUSD:   fmt.Sprintf("$%.4f", float64(mp.OutputPrice)/1_000_000),
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"prices":                prices,
		"fallback_input_price":  payments.DefaultInputPricePerMillion,
		"fallback_output_price": payments.DefaultOutputPricePerMillion,
		"fallback_input_usd":    fmt.Sprintf("$%.4f", float64(payments.DefaultInputPricePerMillion)/1_000_000),
		"fallback_output_usd":   fmt.Sprintf("$%.4f", float64(payments.DefaultOutputPricePerMillion)/1_000_000),
	})
}

// handleAdminPricing handles PUT /v1/admin/pricing.
// Sets platform default prices for a model. Requires a Privy account with
// an admin email. These defaults apply to all users who haven't set custom prices.
func (s *Server) handleAdminPricing(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
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
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
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

// handleAdminSetUserRole handles PUT /v1/admin/users/role.
// Grants or clears an account role (e.g. RoleService for OpenRouter). Admin only.
func (s *Server) handleAdminSetUserRole(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		AccountID string `json:"account_id"`
		Role      string `json:"role"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.AccountID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "account_id is required", withParam("account_id")))
		return
	}
	// Only known roles are accepted. "" clears the role back to a normal account.
	if req.Role != "" && req.Role != store.RoleService {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			fmt.Sprintf("invalid role %q — allowed: %q or \"\"", req.Role, store.RoleService), withParam("role")))
		return
	}

	if err := s.store.SetUserRole(req.AccountID, req.Role); err != nil {
		s.logger.Error("admin set role: failed", "account_id", req.AccountID, "error", err)
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "user not found or update failed"))
		return
	}

	s.logger.Info("admin: user role updated", "account_id", req.AccountID, "role", req.Role)
	writeJSON(w, http.StatusOK, map[string]any{
		"status":     "role_updated",
		"account_id": req.AccountID,
		"role":       req.Role,
	})
}

// handleAdminSetUserPlatformFee handles PUT /v1/admin/users/platform-fee.
// Sets a per-account platform fee override (0–100). Omit platform_fee_percent
// (or send null) to clear the override and fall back to the global default.
// Admin only.
func (s *Server) handleAdminSetUserPlatformFee(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		AccountID          string `json:"account_id"`
		PlatformFeePercent *int64 `json:"platform_fee_percent"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.AccountID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "account_id is required", withParam("account_id")))
		return
	}
	if req.PlatformFeePercent != nil && (*req.PlatformFeePercent < 0 || *req.PlatformFeePercent > 100) {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"platform_fee_percent must be between 0 and 100", withParam("platform_fee_percent")))
		return
	}

	if err := s.store.SetUserPlatformFeePercent(req.AccountID, req.PlatformFeePercent); err != nil {
		s.logger.Error("admin set platform fee: failed", "account_id", req.AccountID, "error", err)
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "user not found or update failed"))
		return
	}

	resp := map[string]any{
		"status":     "platform_fee_updated",
		"account_id": req.AccountID,
	}
	if req.PlatformFeePercent != nil {
		resp["platform_fee_percent"] = *req.PlatformFeePercent
	} else {
		resp["platform_fee_percent"] = nil
		resp["note"] = "override cleared — using global default"
	}
	s.logger.Info("admin: user platform fee updated", "account_id", req.AccountID, "fee", req.PlatformFeePercent)
	writeJSON(w, http.StatusOK, resp)
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
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
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
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
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

// handleModelCatalog handles GET /v1/models/catalog.
// Public endpoint — returns active models for providers and the install script.
// Cached for 60s — the underlying DB query is fast but this endpoint is hit
// by every provider heartbeat and install script poll.
func modelCatalogCacheKey(typeFilter string, includeAliases bool) string {
	return "models:catalog:type=" + typeFilter + ":include_aliases=" + strconv.FormatBool(includeAliases)
}

func (s *Server) handleModelCatalog(w http.ResponseWriter, r *http.Request) {
	// Optional filter: ?type=text
	typeFilter := strings.TrimSpace(strings.ToLower(r.URL.Query().Get("type")))
	if typeFilter != "" && typeFilter != "text" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "unsupported catalog type", withParam("type")))
		return
	}
	includeAliases := r.URL.Query().Get("include_aliases") == "1" || strings.EqualFold(r.URL.Query().Get("include_aliases"), "true")

	cacheKey := modelCatalogCacheKey(typeFilter, includeAliases)
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	registryRows, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch model catalog"))
		return
	}
	// The catalog is text-only today; an explicit non-text filter yields nothing.
	models := make([]map[string]any, 0, len(registryRows))
	if typeFilter == "" || typeFilter == "text" {
		for i := range registryRows {
			models = append(models, catalogModelFromRegistryRecord(&registryRows[i]))
		}
	}
	response := map[string]any{"models": models}
	if includeAliases {
		aliases, err := s.store.ListModelAliases()
		if err != nil {
			s.logger.Warn("model registry: failed to list aliases for catalog response", "error", err)
		} else {
			response["aliases"] = catalogAliasesForResponse(models, aliases)
		}
	}

	body, err := json.Marshal(response)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to marshal catalog"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}

// handleAdminCredit handles POST /v1/admin/credit.
// Credits a user's non-withdrawable balance by email.
func (s *Server) handleAdminCredit(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Email     string `json:"email"`
		AmountUSD string `json:"amount_usd"`
		Note      string `json:"note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Email == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "email is required"))
		return
	}
	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}
	amountMicroUSD := int64(amountFloat * 1_000_000)

	user, err := s.store.GetUserByEmail(req.Email)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "no user found with email: "+req.Email))
		return
	}

	ref := "admin_credit"
	if req.Note != "" {
		ref = "admin_credit:" + req.Note
	}
	if err := s.store.Credit(user.AccountID, amountMicroUSD, store.LedgerAdminCredit, ref); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to credit: "+err.Error()))
		return
	}

	s.logger.Info("admin credit applied",
		"email", req.Email,
		"account_id", user.AccountID,
		"amount_micro_usd", amountMicroUSD,
		"note", req.Note,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"account_id":    user.AccountID,
		"email":         user.Email,
		"credited_usd":  amountFloat,
		"withdrawable":  false,
		"balance_after": float64(s.store.GetBalance(user.AccountID)) / 1_000_000,
	})
}

// handleAdminReward handles POST /v1/admin/reward.
// Credits a user's withdrawable balance by email (treated as earnings).
func (s *Server) handleAdminReward(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Email     string `json:"email"`
		AmountUSD string `json:"amount_usd"`
		Note      string `json:"note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Email == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "email is required"))
		return
	}
	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}
	amountMicroUSD := int64(amountFloat * 1_000_000)

	user, err := s.store.GetUserByEmail(req.Email)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "no user found with email: "+req.Email))
		return
	}

	ref := "admin_reward"
	if req.Note != "" {
		ref = "admin_reward:" + req.Note
	}
	if err := s.store.CreditWithdrawable(user.AccountID, amountMicroUSD, store.LedgerAdminReward, ref); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to reward: "+err.Error()))
		return
	}

	s.logger.Info("admin reward applied",
		"email", req.Email,
		"account_id", user.AccountID,
		"amount_micro_usd", amountMicroUSD,
		"note", req.Note,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":                 true,
		"account_id":         user.AccountID,
		"email":              user.Email,
		"rewarded_usd":       amountFloat,
		"withdrawable":       true,
		"balance_after":      float64(s.store.GetBalance(user.AccountID)) / 1_000_000,
		"withdrawable_after": float64(s.store.GetWithdrawableBalance(user.AccountID)) / 1_000_000,
	})
}

// handleAccountEarnings handles GET /v1/provider/account-earnings?limit=50.
// Returns recent earnings history, lifetime aggregates, and current account balance
// for the authenticated provider account.
// Cached for 20s per account — dashboard polls this frequently.
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

	cacheKey := "account-earnings:" + accountID + ":" + strconv.Itoa(limit)
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
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

	availableBalance, withdrawableBalance := s.store.GetBalanceWithWithdrawable(accountID)

	body, err := json.Marshal(map[string]any{
		"account_id":                     accountID,
		"earnings":                       earnings,
		"total_micro_usd":                summary.TotalMicroUSD,
		"total_usd":                      fmt.Sprintf("%.6f", float64(summary.TotalMicroUSD)/1_000_000),
		"count":                          summary.Count,
		"recent_count":                   len(earnings),
		"history_limit":                  limit,
		"available_balance_micro_usd":    availableBalance,
		"available_balance_usd":          fmt.Sprintf("%.6f", float64(availableBalance)/1_000_000),
		"withdrawable_balance_micro_usd": withdrawableBalance,
		"withdrawable_balance_usd":       fmt.Sprintf("%.6f", float64(withdrawableBalance)/1_000_000),
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to marshal earnings"))
		return
	}
	s.readCache.Set(cacheKey, body, 20*time.Second)
	writeCachedJSON(w, body)
}
