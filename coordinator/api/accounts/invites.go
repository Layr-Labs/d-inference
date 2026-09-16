package accounts

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// CreateInvite handles POST /v1/admin/invite-codes.
func (s *Controller) CreateInvite(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}

	var req struct {
		Code      string  `json:"code"`
		AmountUSD float64 `json:"amount_usd"`
		MaxUses   int     `json:"max_uses"`
		ExpiresAt string  `json:"expires_at,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	if req.AmountUSD <= 0 {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "amount_usd must be positive"))
		return
	}

	// Auto-generate code if empty
	code := strings.ToUpper(strings.TrimSpace(req.Code))
	if code == "" {
		b := make([]byte, 4)
		rand.Read(b)
		code = "INV-" + strings.ToUpper(hex.EncodeToString(b))
	}

	amountMicroUSD := int64(req.AmountUSD * 1_000_000)
	if req.MaxUses < 0 {
		req.MaxUses = 0
	}
	if req.MaxUses == 0 {
		req.MaxUses = 1 // default single-use
	}

	ic := &store.InviteCode{
		Code:           code,
		AmountMicroUSD: amountMicroUSD,
		MaxUses:        req.MaxUses,
		Active:         true,
		CreatedAt:      time.Now(),
	}

	if req.ExpiresAt != "" {
		t, err := time.Parse(time.RFC3339, req.ExpiresAt)
		if err != nil {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid expires_at: "+err.Error()))
			return
		}
		ic.ExpiresAt = &t
	}

	if err := s.store().CreateInviteCode(ic); err != nil {
		httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("conflict", err.Error()))
		return
	}

	s.logger.Info("invite code created", "code", code, "amount_usd", req.AmountUSD, "max_uses", req.MaxUses)
	httpresponse.WriteJSON(w, http.StatusCreated, map[string]any{
		"code":       code,
		"amount_usd": fmt.Sprintf("%.2f", float64(amountMicroUSD)/1_000_000),
		"max_uses":   req.MaxUses,
		"expires_at": ic.ExpiresAt,
	})
}

// ListInvites handles GET /v1/admin/invite-codes.
func (s *Controller) ListInvites(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}

	codes := s.store().ListInviteCodes()
	type codeView struct {
		Code      string     `json:"code"`
		AmountUSD string     `json:"amount_usd"`
		MaxUses   int        `json:"max_uses"`
		UsedCount int        `json:"used_count"`
		Active    bool       `json:"active"`
		ExpiresAt *time.Time `json:"expires_at,omitempty"`
		CreatedAt time.Time  `json:"created_at"`
	}

	views := make([]codeView, len(codes))
	for i, c := range codes {
		views[i] = codeView{
			Code:      c.Code,
			AmountUSD: fmt.Sprintf("%.2f", float64(c.AmountMicroUSD)/1_000_000),
			MaxUses:   c.MaxUses,
			UsedCount: c.UsedCount,
			Active:    c.Active,
			ExpiresAt: c.ExpiresAt,
			CreatedAt: c.CreatedAt,
		}
	}

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"invite_codes": views})
}

// DeactivateInvite handles DELETE /v1/admin/invite-codes.
func (s *Controller) DeactivateInvite(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}

	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON"))
		return
	}
	if req.Code == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "code is required"))
		return
	}

	if err := s.store().DeactivateInviteCode(req.Code); err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", err.Error()))
		return
	}

	s.logger.Info("invite code deactivated", "code", req.Code)
	httpresponse.WriteJSON(w, http.StatusOK, map[string]string{"status": "deactivated"})
}

// RedeemInvite handles POST /v1/invite/redeem.
func (s *Controller) RedeemInvite(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON"))
		return
	}

	code := strings.ToUpper(strings.TrimSpace(req.Code))
	if code == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "code is required"))
		return
	}

	accountID := requestcontext.AccountID(r.Context())

	// Get the invite code to know the amount
	ic, err := s.store().GetInviteCode(code)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "invalid invite code"))
		return
	}

	// Claim and credit together; a failed balance write leaves the invite usable.
	if err := s.store().RedeemInviteCode(code, accountID); err != nil {
		if errors.Is(err, store.ErrInviteCredit) {
			s.logger.Error("failed to credit invite balance", "account", accountID, "code", code, "error", err)
			httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to credit balance"))
		} else {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", err.Error()))
		}
		return
	}

	balance := s.store().GetBalance(accountID)
	s.logger.Info("invite code redeemed", "code", code, "account", accountID, "amount_micro_usd", ic.AmountMicroUSD)

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"credited_usd": fmt.Sprintf("%.2f", float64(ic.AmountMicroUSD)/1_000_000),
		"balance_usd":  fmt.Sprintf("%.6f", float64(balance)/1_000_000),
	})
}
