package billing

import (
	"encoding/json"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/api/modelprice"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
)

// handleGetPricing handles GET /v1/pricing.
// Public endpoint — returns the platform price rows (set via the admin
// endpoint and model registration) plus the fallback defaults. Every entry
// carries the effective cache-read rate, derived when the row sets none, so
// consumers see the rate cached prompt tokens actually settle at.
func (s *Owner) HandleGetPricing(w http.ResponseWriter, r *http.Request) {
	// All model prices come from the database (set via PUT /v1/admin/pricing).
	platformPrices := s.store.ListModelPrices("platform")
	prices := make([]types.PriceEntry, 0, len(platformPrices))
	for _, mp := range platformPrices {
		prices = append(prices, types.PriceEntry{Model: mp.Model, ModelPriceQuote: modelprice.Quote(mp)})
	}

	fallback := modelprice.RatesQuote(payments.DefaultRates())
	httpx.WriteJSON(w, http.StatusOK, types.PricingResponse{
		Prices:                 prices,
		FallbackInputPrice:     fallback.InputPrice,
		FallbackOutputPrice:    fallback.OutputPrice,
		FallbackCacheReadPrice: fallback.CacheReadPrice,
		FallbackInputUSD:       fallback.InputUSD,
		FallbackOutputUSD:      fallback.OutputUSD,
		FallbackCacheReadUSD:   fallback.CacheReadUSD,
	})
}

// handleAdminPricing handles PUT /v1/admin/pricing.
// Sets platform default prices for a model. Requires a Privy account with
// an admin email. These defaults apply to all users who haven't set custom prices.
func (s *Owner) HandleAdminPricing(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Model string `json:"model"`
		modelprice.Input
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "model is required", httpx.WithParam("model")))
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}

	// Store under the special "platform" account.
	price := req.ModelPrice("platform", req.Model)
	if err := s.store.SetModelPrice(price); err != nil {
		s.logger.Error("admin pricing: set failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to set price"))
		return
	}

	quote := modelprice.Quote(price)
	s.logger.Info("admin: platform price updated",
		"model", req.Model,
		"input_price", quote.InputPrice,
		"output_price", quote.OutputPrice,
		"cache_read_price", quote.CacheReadPrice,
	)
	httpx.WriteJSON(w, http.StatusOK, types.PriceUpdateResponse{Status: "platform_default_updated", Model: req.Model, ModelPriceQuote: quote})
}

// handleSetPricing handles PUT /v1/pricing.
// Providers set custom prices for models they serve. Requires Privy auth.
func (s *Owner) HandleSetPricing(w http.ResponseWriter, r *http.Request) {
	if access.RequirePrivyUser(w, r) == nil {
		return
	}
	var req struct {
		Model string `json:"model"`
		modelprice.Input
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "model is required", httpx.WithParam("model")))
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}

	price := req.ModelPrice(access.ResolveAccountID(r), req.Model)
	if err := s.store.SetModelPrice(price); err != nil {
		s.logger.Error("pricing: set failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to set price"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, types.PriceUpdateResponse{Status: "updated", Model: req.Model, ModelPriceQuote: modelprice.Quote(price)})
}

// handleDeletePricing handles DELETE /v1/pricing.
// Removes a custom price override, reverting to platform defaults.
func (s *Owner) HandleDeletePricing(w http.ResponseWriter, r *http.Request) {
	if access.RequirePrivyUser(w, r) == nil {
		return
	}
	var req struct {
		Model string `json:"model"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "model is required", httpx.WithParam("model")))
		return
	}

	accountID := access.ResolveAccountID(r)
	if err := s.store.DeleteModelPrice(accountID, req.Model); err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", err.Error()))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"status": "deleted",
		"model":  req.Model,
	})
}
