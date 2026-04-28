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
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/payments"
	providerpricing "github.com/eigeninference/coordinator/internal/pricing"
	"github.com/eigeninference/coordinator/internal/registry"
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

type providerPricingActor struct {
	AccountID string
}

func (s *Server) providerPricingActor(w http.ResponseWriter, r *http.Request) (*providerPricingActor, bool) {
	token := extractBearerToken(r)
	if token == "" {
		writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "missing credentials — use Authorization: Bearer <token>"))
		return nil, false
	}

	if pt, err := s.store.GetProviderToken(token); err == nil && pt != nil && pt.Active {
		return &providerPricingActor{AccountID: pt.AccountID}, true
	}

	if s.privyAuth != nil && strings.HasPrefix(token, "eyJ") {
		privyUserID, err := s.privyAuth.VerifyToken(token)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid Privy token"))
			return nil, false
		}
		user, err := s.privyAuth.GetOrCreateUser(privyUserID)
		if err != nil {
			s.logger.Error("privy: user resolution failed", "error", err)
			writeJSON(w, http.StatusInternalServerError, errorResponse("auth_error", "failed to resolve user"))
			return nil, false
		}
		return &providerPricingActor{AccountID: user.AccountID}, true
	}

	if s.store.ValidateKey(token) {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "provider pricing requires a Privy session or provider device token"))
		return nil, false
	}

	writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid credentials"))
	return nil, false
}

type providerDiscountResponse struct {
	AccountID       string  `json:"account_id,omitempty"`
	ProviderKey     string  `json:"provider_key,omitempty"`
	Model           string  `json:"model,omitempty"`
	Scope           string  `json:"scope"`
	DiscountBPS     int     `json:"discount_bps"`
	DiscountPercent float64 `json:"discount_percent"`
}

type providerEffectivePriceResponse struct {
	Model           string  `json:"model"`
	BaseInputPrice  int64   `json:"base_input_price"`
	BaseOutputPrice int64   `json:"base_output_price"`
	InputPrice      int64   `json:"input_price"`
	OutputPrice     int64   `json:"output_price"`
	DiscountBPS     int     `json:"discount_bps"`
	DiscountPercent float64 `json:"discount_percent"`
	DiscountScope   string  `json:"discount_scope,omitempty"`
	InputUSD        string  `json:"input_usd"`
	OutputUSD       string  `json:"output_usd"`
}

func providerDiscountToResponse(d store.ProviderDiscount) providerDiscountResponse {
	return providerDiscountResponse{
		AccountID:       d.AccountID,
		ProviderKey:     d.ProviderKey,
		Model:           d.Model,
		Scope:           d.Scope(),
		DiscountBPS:     d.DiscountBPS,
		DiscountPercent: providerpricing.DiscountPercentFromBPS(d.DiscountBPS),
	}
}

func effectivePriceToResponse(ep providerpricing.EffectivePrice) providerEffectivePriceResponse {
	return providerEffectivePriceResponse{
		Model:           ep.Model,
		BaseInputPrice:  ep.BaseInputPrice,
		BaseOutputPrice: ep.BaseOutputPrice,
		InputPrice:      ep.InputPrice,
		OutputPrice:     ep.OutputPrice,
		DiscountBPS:     ep.DiscountBPS,
		DiscountPercent: ep.DiscountPercent,
		DiscountScope:   ep.DiscountScope,
		InputUSD:        fmt.Sprintf("$%.4f", float64(ep.InputPrice)/1_000_000),
		OutputUSD:       fmt.Sprintf("$%.4f", float64(ep.OutputPrice)/1_000_000),
	}
}

func (s *Server) handleMyPricing(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.providerPricingActor(w, r)
	if !ok {
		return
	}

	discounts := s.store.ListProviderDiscounts(actor.AccountID)
	sort.Slice(discounts, func(i, j int) bool {
		if discounts[i].ProviderKey != discounts[j].ProviderKey {
			return discounts[i].ProviderKey < discounts[j].ProviderKey
		}
		return discounts[i].Model < discounts[j].Model
	})
	discountResp := make([]providerDiscountResponse, 0, len(discounts))
	for _, d := range discounts {
		discountResp = append(discountResp, providerDiscountToResponse(d))
	}

	priceModels := make(map[string]struct{})
	for model := range payments.DefaultPrices() {
		priceModels[model] = struct{}{}
	}
	for _, mp := range s.store.ListModelPrices("platform") {
		priceModels[mp.Model] = struct{}{}
	}
	models := make([]string, 0, len(priceModels))
	for model := range priceModels {
		models = append(models, model)
	}
	sort.Strings(models)

	prices := make([]providerEffectivePriceResponse, 0, len(models))
	for _, model := range models {
		prices = append(prices, effectivePriceToResponse(providerpricing.EffectiveModelPrice(s.store, actor.AccountID, "", model)))
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"account_id":           actor.AccountID,
		"discounts":            discountResp,
		"prices":               prices,
		"max_discount_percent": providerpricing.DiscountPercentFromBPS(providerpricing.MaxProviderDiscountBPS),
	})
}

func (s *Server) handleSetProviderDiscount(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.providerPricingActor(w, r)
	if !ok {
		return
	}

	var req struct {
		ProviderKey     string  `json:"provider_key"`
		Model           string  `json:"model"`
		DiscountPercent float64 `json:"discount_percent"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	req.ProviderKey = strings.TrimSpace(req.ProviderKey)
	req.Model = strings.TrimSpace(req.Model)

	discountBPS, err := providerpricing.DiscountBPSFromPercent(req.DiscountPercent)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if req.ProviderKey != "" && !s.providerKeyBelongsToAccount(r.Context(), actor.AccountID, req.ProviderKey) {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "provider_key does not belong to this account"))
		return
	}

	if err := s.store.SetProviderDiscount(actor.AccountID, req.ProviderKey, req.Model, discountBPS); err != nil {
		s.logger.Error("provider discount: set failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to set discount"))
		return
	}
	d, _ := s.store.GetProviderDiscount(actor.AccountID, req.ProviderKey, req.Model)
	writeJSON(w, http.StatusOK, map[string]any{
		"status":   "updated",
		"discount": providerDiscountToResponse(d),
	})
}

func (s *Server) handleDeleteProviderDiscount(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.providerPricingActor(w, r)
	if !ok {
		return
	}

	var req struct {
		ProviderKey string `json:"provider_key"`
		Model       string `json:"model"`
	}
	if r.Body != nil {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
			return
		}
	}
	q := r.URL.Query()
	if q.Has("provider_key") {
		req.ProviderKey = q.Get("provider_key")
	}
	if q.Has("model") {
		req.Model = q.Get("model")
	}
	req.ProviderKey = strings.TrimSpace(req.ProviderKey)
	req.Model = strings.TrimSpace(req.Model)

	if req.ProviderKey != "" && !s.providerKeyBelongsToAccount(r.Context(), actor.AccountID, req.ProviderKey) {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "provider_key does not belong to this account"))
		return
	}

	if err := s.store.DeleteProviderDiscount(actor.AccountID, req.ProviderKey, req.Model); err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "deleted",
		"provider_key": req.ProviderKey,
		"model":        req.Model,
	})
}

func (s *Server) providerKeyBelongsToAccount(ctx context.Context, accountID, providerKey string) bool {
	if strings.TrimSpace(providerKey) == "" {
		return true
	}
	records, err := s.store.ListProvidersByAccount(ctx, accountID)
	if err == nil {
		for _, rec := range records {
			if rec.ID == providerKey || rec.SerialNumber == providerKey || rec.SEPublicKey == providerKey {
				return true
			}
		}
	}
	found := false
	s.registry.ForEachProvider(func(p *registry.Provider) {
		if found {
			return
		}
		p.Mu().Lock()
		defer p.Mu().Unlock()
		if p.AccountID != accountID {
			return
		}
		if p.ID == providerKey || p.PublicKey == providerKey {
			found = true
			return
		}
		if p.AttestationResult != nil {
			if p.AttestationResult.SerialNumber == providerKey || p.AttestationResult.PublicKey == providerKey {
				found = true
			}
		}
	})
	return found
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
		if !m.Active || IsRetiredProviderModel(m) {
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
	withdrawableBalance := s.store.GetWithdrawableBalance(accountID)

	writeJSON(w, http.StatusOK, map[string]any{
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
}
