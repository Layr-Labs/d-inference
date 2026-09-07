package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
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
		s.writeReferralError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"code":          referrer.Code,
		"share_percent": s.billing.Referral().SharePercent(),
		"reward_basis":  "consumer_spend",
		"message":       fmt.Sprintf("Share your code %s — you earn %d%% of the token spend charged to consumers you refer.", referrer.Code, s.billing.Referral().SharePercent()),
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
		s.writeReferralError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "applied",
		"code":    strings.ToUpper(strings.TrimSpace(req.Code)),
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
		if errors.Is(err, store.ErrNotFound) {
			writeJSON(w, http.StatusNotFound, errorResponse("referral_error", "not a registered referrer"))
		} else {
			s.writeReferralError(w, err)
		}
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
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.writeReferralError(w, err)
		return
	}
	code := ""
	if referrer != nil {
		code = referrer.Code
	}
	referredBy, err := s.billing.Store().GetReferrerForAccount(accountID)
	if err != nil {
		s.writeReferralError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"code": code, "share_percent": s.billing.Referral().SharePercent(), "reward_basis": "consumer_spend", "referred_by": referredBy,
	})
}

func (s *Server) writeReferralError(w http.ResponseWriter, err error) {
	if errors.Is(err, billing.ErrInvalidReferral) || errors.Is(err, store.ErrReferralConflict) {
		writeJSON(w, http.StatusBadRequest, errorResponse("referral_error", err.Error()))
		return
	}
	s.logger.Error("referral operation failed", "error", err)
	writeJSON(w, http.StatusServiceUnavailable, errorResponse("referral_error", "Referral service is temporarily unavailable. Please try again."))
}
