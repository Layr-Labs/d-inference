package billing

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
)

func (s *Controller) ReferralRegister(w http.ResponseWriter, r *http.Request) {
	if s.billing() == nil || s.billing().Referral() == nil {
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("billing_error", "referral system not available"))
		return
	}
	if requestauth.RequirePrivyUser(w, r) == nil {
		return
	}

	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Code == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "code is required — choose your own referral code (3-20 chars, alphanumeric)"))
		return
	}

	accountID := requestauth.ResolveAccountID(r)
	referrer, err := s.billing().Referral().Register(accountID, req.Code)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("referral_error", err.Error()))
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"code":          referrer.Code,
		"share_percent": s.billing().Referral().SharePercent(),
		"message":       fmt.Sprintf("Share your code %s — you earn %d%% of the platform fee on every inference by referred users.", referrer.Code, s.billing().Referral().SharePercent()),
	})
}

func (s *Controller) ReferralApply(w http.ResponseWriter, r *http.Request) {
	if s.billing() == nil || s.billing().Referral() == nil {
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("billing_error", "referral system not available"))
		return
	}
	if requestauth.RequirePrivyUser(w, r) == nil {
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Code == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "code is required"))
		return
	}
	accountID := requestauth.ResolveAccountID(r)
	if err := s.billing().Referral().Apply(accountID, req.Code); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("referral_error", err.Error()))
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"status":  "applied",
		"code":    req.Code,
		"message": "Referral code applied successfully.",
	})
}

func (s *Controller) ReferralStats(w http.ResponseWriter, r *http.Request) {
	if s.billing() == nil || s.billing().Referral() == nil {
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("billing_error", "referral system not available"))
		return
	}
	accountID := requestauth.ResolveAccountID(r)
	stats, err := s.billing().Referral().Stats(accountID)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("referral_error", err.Error()))
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, stats)
}

func (s *Controller) ReferralInfo(w http.ResponseWriter, r *http.Request) {
	if s.billing() == nil || s.billing().Referral() == nil {
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("billing_error", "referral system not available"))
		return
	}
	accountID := requestauth.ResolveAccountID(r)
	referrer, err := s.billing().Store().GetReferrerByAccount(accountID)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("referral_error", "not a registered referrer — use POST /v1/referral/register"))
		return
	}
	referredBy, _ := s.billing().Store().GetReferrerForAccount(accountID)
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"code":          referrer.Code,
		"share_percent": s.billing().Referral().SharePercent(),
		"referred_by":   referredBy,
	})
}
