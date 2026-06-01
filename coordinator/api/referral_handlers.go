package api

import (
	"fmt"
	"net/http"
)

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
	if !decodeJSONBody(w, r, &req) {
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
	if !decodeJSONBody(w, r, &req) {
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
