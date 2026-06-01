package api

import (
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/payments"
)

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
	if !decodeJSONBody(w, r, &req) {
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
	if !decodeJSONBody(w, r, &req) {
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
