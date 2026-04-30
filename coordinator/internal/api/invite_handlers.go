package api

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/darkbloom/coordinator/internal/auth"
	"github.com/darkbloom/coordinator/internal/store"
)

// requireAdminKey checks that the request is from an admin (either admin key or Privy admin).
// Returns true if authorized, false if it wrote an error response.
func (s *Server) requireAdminKey(w http.ResponseWriter, r *http.Request) bool {
	// Check 1: Bearer token matches admin key
	token := extractBearerToken(r)
	if token != "" && s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
		return true
	}

	// Check 2: Privy admin
	user := auth.UserFromContext(r.Context())
	if user != nil && s.isAdmin(user) {
		return true
	}

	writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
	return false
}

// handleAdminCreateInviteCode handles POST /v1/admin/invite-codes.
func (s *Server) handleAdminCreateInviteCode(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}

	var req struct {
		Code      string  `json:"code"`
		AmountUSD float64 `json:"amount_usd"`
		MaxUses   int     `json:"max_uses"`
		ExpiresAt string  `json:"expires_at,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	if req.AmountUSD <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be positive"))
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
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid expires_at: "+err.Error()))
			return
		}
		ic.ExpiresAt = &t
	}

	if err := s.store.CreateInviteCode(ic); err != nil {
		writeJSON(w, http.StatusConflict, errorResponse("conflict", err.Error()))
		return
	}

	s.logger.Info("invite code created", "code", code, "amount_usd", req.AmountUSD, "max_uses", req.MaxUses)
	writeJSON(w, http.StatusCreated, map[string]any{
		"code":       code,
		"amount_usd": fmt.Sprintf("%.2f", float64(amountMicroUSD)/1_000_000),
		"max_uses":   req.MaxUses,
		"expires_at": ic.ExpiresAt,
	})
}

// handleAdminListInviteCodes handles GET /v1/admin/invite-codes.
func (s *Server) handleAdminListInviteCodes(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}

	codes := s.store.ListInviteCodes()
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

	writeJSON(w, http.StatusOK, map[string]any{"invite_codes": views})
}

// handleAdminDeactivateInviteCode handles DELETE /v1/admin/invite-codes.
func (s *Server) handleAdminDeactivateInviteCode(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}

	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON"))
		return
	}
	if req.Code == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "code is required"))
		return
	}

	if err := s.store.DeactivateInviteCode(req.Code); err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
		return
	}

	s.logger.Info("invite code deactivated", "code", req.Code)
	writeJSON(w, http.StatusOK, map[string]string{"status": "deactivated"})
}

// handleRedeemInviteCode handles POST /v1/invite/redeem.
func (s *Server) handleRedeemInviteCode(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON"))
		return
	}

	code := strings.ToUpper(strings.TrimSpace(req.Code))
	if code == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "code is required"))
		return
	}

	accountID := consumerKeyFromContext(r.Context())

	// Get the invite code to know the amount
	ic, err := s.store.GetInviteCode(code)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "invalid invite code"))
		return
	}

	// Redeem atomically (checks active, expiry, max uses, double-redemption)
	if err := s.store.RedeemInviteCode(code, accountID); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}

	// Credit the user's balance
	if err := s.store.Credit(accountID, ic.AmountMicroUSD, store.LedgerInviteCredit, "invite:"+code); err != nil {
		s.logger.Error("failed to credit invite balance", "account", accountID, "code", code, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to credit balance"))
		return
	}

	balance := s.store.GetBalance(accountID)
	s.logger.Info("invite code redeemed", "code", code, "account", accountID, "amount_micro_usd", ic.AmountMicroUSD)

	writeJSON(w, http.StatusOK, map[string]any{
		"credited_usd": fmt.Sprintf("%.2f", float64(ic.AmountMicroUSD)/1_000_000),
		"balance_usd":  fmt.Sprintf("%.6f", float64(balance)/1_000_000),
	})
}
