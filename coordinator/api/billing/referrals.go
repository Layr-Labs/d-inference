package billing

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) HandleReferralRegister(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "referral system not available"))
		return
	}
	if access.RequirePrivyUser(w, r) == nil {
		return
	}

	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Code == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "code is required — choose your own referral code (3-20 chars, alphanumeric)"))
		return
	}

	accountID := access.ResolveAccountID(r)
	referrer, err := s.billing.Referral().Register(accountID, req.Code)
	if err != nil {
		s.writeReferralError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"code":          referrer.Code,
		"share_percent": s.billing.Referral().SharePercent(),
		"reward_basis":  "consumer_spend",
		"message":       fmt.Sprintf("Share your code %s - you earn %d%% of the token spend charged to consumers you refer.", referrer.Code, s.billing.Referral().SharePercent()),
	})
}

func (s *Owner) HandleReferralApply(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "referral system not available"))
		return
	}
	if access.RequirePrivyUser(w, r) == nil {
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Code == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "code is required"))
		return
	}
	accountID := access.ResolveAccountID(r)
	if err := s.billing.Referral().Apply(accountID, req.Code); err != nil {
		s.writeReferralError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"status":  "applied",
		"code":    strings.ToUpper(strings.TrimSpace(req.Code)),
		"message": "Referral code applied successfully.",
	})
}

func (s *Owner) HandleReferralStats(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "referral system not available"))
		return
	}
	accountID := access.ResolveAccountID(r)
	stats, err := s.billing.Referral().Stats(accountID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("referral_error", "not a registered referrer"))
		} else {
			s.writeReferralError(w, err)
		}
		return
	}
	httpx.WriteJSON(w, http.StatusOK, stats)
}

func (s *Owner) HandleReferralInfo(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil || s.billing.Referral() == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("billing_error", "referral system not available"))
		return
	}
	accountID := access.ResolveAccountID(r)
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
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"code":          code,
		"share_percent": s.billing.Referral().SharePercent(),
		"reward_basis":  "consumer_spend",
		"referred_by":   referredBy,
	})
}

func (s *Owner) writeReferralError(w http.ResponseWriter, err error) {
	if errors.Is(err, billingservice.ErrInvalidReferral) || errors.Is(err, store.ErrReferralConflict) {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("referral_error", err.Error()))
		return
	}
	s.logger.Error("referral operation failed", "error", err)
	httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("referral_error", "Referral service is temporarily unavailable. Please try again."))
}
