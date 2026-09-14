package billing

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
	"github.com/eigeninference/d-inference/coordinator/payments"
)

// GetPricing handles GET /v1/pricing.
// Public endpoint — returns platform default prices. Also overlays platform
// DB overrides (set via admin endpoint).
func (s *Controller) GetPricing(w http.ResponseWriter, r *http.Request) {
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

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"prices":                prices,
		"fallback_input_price":  payments.DefaultInputPricePerMillion,
		"fallback_output_price": payments.DefaultOutputPricePerMillion,
		"fallback_input_usd":    fmt.Sprintf("$%.4f", float64(payments.DefaultInputPricePerMillion)/1_000_000),
		"fallback_output_usd":   fmt.Sprintf("$%.4f", float64(payments.DefaultOutputPricePerMillion)/1_000_000),
	})
}

// AdminPricing handles PUT /v1/admin/pricing.
// Sets platform default prices for a model. Requires a Privy account with
// an admin email. These defaults apply to all users who haven't set custom prices.
func (s *Controller) AdminPricing(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}

	var req struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`
		OutputPrice int64  `json:"output_price"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "model is required", httpresponse.WithParam("model")))
		return
	}
	if req.InputPrice <= 0 || req.OutputPrice <= 0 {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "input_price and output_price must be positive"))
		return
	}

	// Store under the special "platform" account.
	if err := s.store.SetModelPrice("platform", req.Model, req.InputPrice, req.OutputPrice); err != nil {
		s.logger.Error("admin pricing: set failed", "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to set price"))
		return
	}

	s.logger.Info("admin: platform price updated",
		"model", req.Model,
		"input_price", req.InputPrice,
		"output_price", req.OutputPrice,
	)

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"status":       "platform_default_updated",
		"model":        req.Model,
		"input_price":  req.InputPrice,
		"output_price": req.OutputPrice,
		"input_usd":    fmt.Sprintf("$%.4f per 1M tokens", float64(req.InputPrice)/1_000_000),
		"output_usd":   fmt.Sprintf("$%.4f per 1M tokens", float64(req.OutputPrice)/1_000_000),
	})
}

// SetPricing handles PUT /v1/pricing.
// Providers set custom prices for models they serve. Requires Privy auth.
func (s *Controller) SetPricing(w http.ResponseWriter, r *http.Request) {
	if requestauth.RequirePrivyUser(w, r) == nil {
		return
	}
	var req struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`
		OutputPrice int64  `json:"output_price"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "model is required", httpresponse.WithParam("model")))
		return
	}
	if req.InputPrice <= 0 || req.OutputPrice <= 0 {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "input_price and output_price must be positive (micro-USD per 1M tokens)"))
		return
	}

	accountID := requestauth.ResolveAccountID(r)
	if err := s.store.SetModelPrice(accountID, req.Model, req.InputPrice, req.OutputPrice); err != nil {
		s.logger.Error("pricing: set failed", "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to set price"))
		return
	}

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"status":       "updated",
		"model":        req.Model,
		"input_price":  req.InputPrice,
		"output_price": req.OutputPrice,
		"input_usd":    fmt.Sprintf("$%.4f per 1M tokens", float64(req.InputPrice)/1_000_000),
		"output_usd":   fmt.Sprintf("$%.4f per 1M tokens", float64(req.OutputPrice)/1_000_000),
	})
}

// DeletePricing handles DELETE /v1/pricing.
// Removes a custom price override, reverting to platform defaults.
func (s *Controller) DeletePricing(w http.ResponseWriter, r *http.Request) {
	if requestauth.RequirePrivyUser(w, r) == nil {
		return
	}
	var req struct {
		Model string `json:"model"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "model is required", httpresponse.WithParam("model")))
		return
	}

	accountID := requestauth.ResolveAccountID(r)
	if err := s.store.DeleteModelPrice(accountID, req.Model); err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", err.Error()))
		return
	}

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"status": "deleted",
		"model":  req.Model,
	})
}
