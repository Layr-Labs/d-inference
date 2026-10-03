package api

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Account erasure admin API. The flow is plan (dry run + confirm token),
// confirm (soft delete, grace period starts), then a background scrub after
// the grace period, or at once with force. Runbook:
// docs/operations/account-erasure.md.

// erasureConfirmTTL is how long a plan's confirm token is valid.
const erasureConfirmTTL = 15 * time.Minute

type erasurePlanBody struct {
	WalletAddresses []string `json:"wallet_addresses"`
}

type erasurePlanResponse struct {
	*store.ErasurePlan
	RequestID        string    `json:"request_id"`
	ConfirmToken     string    `json:"confirm_token"`
	ConfirmExpiresAt time.Time `json:"confirm_expires_at"`
	GraceSeconds     int64     `json:"grace_seconds"`
}

type erasureConfirmBody struct {
	ConfirmToken    string   `json:"confirm_token"`
	Email           string   `json:"email"`
	Reason          string   `json:"reason"`
	WalletAddresses []string `json:"wallet_addresses"`
	Force           bool     `json:"force"`
}

type erasureRequestResponse struct {
	Request *store.ErasureRequest `json:"request"`
	// ScrubError is set when force=true and the scrub failed; the account
	// stays soft deleted and the background loop retries.
	ScrubError string `json:"scrub_error,omitempty"`
}

type erasureStatusResponse struct {
	Request *store.ErasureRequest     `json:"request"`
	Outbox  []store.ErasureOutboxItem `json:"outbox"`
}

// adminActor names the admin who acted: the admin key, or the account of a
// Privy admin. It never holds an email.
func (s *Server) adminActor(r *http.Request) string {
	token := extractBearerToken(r)
	if token != "" && s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
		return "admin_key"
	}
	if user := auth.UserFromContext(r.Context()); user != nil {
		return "account:" + user.AccountID
	}
	return "unknown"
}

// writeErasureError maps store erasure errors to HTTP answers.
func writeErasureError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "account or erasure request not found"))
	case errors.Is(err, store.ErrErasureConfirmToken):
		writeJSON(w, http.StatusForbidden, errorResponse("invalid_confirm_token", "confirm token is invalid or expired; run the plan again"))
	case errors.Is(err, store.ErrErasureEmailMismatch):
		writeJSON(w, http.StatusBadRequest, errorResponse("email_mismatch", "email does not match the account email shown in the plan", withParam("email")))
	case errors.Is(err, store.ErrErasureOpenWithdrawal):
		writeJSON(w, http.StatusConflict, errorResponse("open_withdrawal", "the account has a withdrawal that is not in a terminal state"))
	case errors.Is(err, store.ErrErasureConflict):
		writeJSON(w, http.StatusConflict, errorResponse("erasure_conflict", "the erasure request is not in a state that allows this step"))
	default:
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "account erasure failed"))
	}
}

func erasureAccountID(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := strings.TrimSpace(r.PathValue("account_id"))
	if id == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "account_id is required", withParam("account_id")))
		return "", false
	}
	return id, true
}

// handleAdminErasurePlan handles POST /v1/admin/accounts/{account_id}/erasure/plan.
// It returns the dry run and a confirm token, and changes no account data.
func (s *Server) handleAdminErasurePlan(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	accountID, ok := erasureAccountID(w, r)
	if !ok {
		return
	}
	var body erasurePlanBody
	r.Body = http.MaxBytesReader(w, r.Body, maxControlPlaneBodyBytes)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error", "request body too large"))
		return
	}
	if len(strings.TrimSpace(string(raw))) > 0 {
		if err := json.Unmarshal(raw, &body); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON"))
			return
		}
	}
	ctx := r.Context()
	plan, err := s.store.PlanAccountErasure(ctx, accountID, body.WalletAddresses)
	if err != nil {
		writeErasureError(w, err)
		return
	}
	token, err := newErasureConfirmToken()
	if err != nil {
		writeErasureError(w, err)
		return
	}
	expires := time.Now().UTC().Add(erasureConfirmTTL)
	req, err := s.store.SaveErasurePlan(ctx, accountID, s.adminActor(r), plan.ErasureCounts, token, expires)
	if errors.Is(err, store.ErrNotFound) {
		// The user row exists (the plan read it) but is no longer live.
		err = store.ErrErasureConflict
	}
	if err != nil {
		writeErasureError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, erasurePlanResponse{
		ErasurePlan: plan, RequestID: req.ID, ConfirmToken: token, ConfirmExpiresAt: expires,
		GraceSeconds: int64(s.erasureGrace / time.Second),
	})
}

// handleAdminErasureRequest handles POST /v1/admin/accounts/{account_id}/erasure.
// It soft deletes the account (revoking its keys and provider tokens),
// disconnects its providers, and with force=true scrubs at once.
func (s *Server) handleAdminErasureRequest(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	accountID, ok := erasureAccountID(w, r)
	if !ok {
		return
	}
	var body erasureConfirmBody
	if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &body) {
		return
	}
	if body.ConfirmToken == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "confirm_token is required", withParam("confirm_token")))
		return
	}
	ctx := r.Context()
	req, err := s.store.RequestAccountErasure(ctx, store.ErasureConfirm{
		AccountID: accountID, ConfirmToken: body.ConfirmToken, Email: body.Email,
		Actor: s.adminActor(r), Reason: body.Reason, WalletAddresses: body.WalletAddresses,
		Now: time.Now().UTC(), Grace: s.erasureGrace,
	})
	if err != nil {
		writeErasureError(w, err)
		return
	}
	// The tokens are revoked in the commit above, so a provider that
	// reconnects after this disconnect comes back unlinked.
	s.invalidateAllAPIKeyCache()
	disconnected := s.registry.DisconnectAccount(accountID)
	s.logger.Info("account erasure requested", "request_id", req.ID, "account_id", accountID,
		"actor", req.Actor, "providers_disconnected", disconnected, "force", body.Force)

	resp := erasureRequestResponse{Request: req}
	if body.Force {
		res, err := s.scrubErasure(ctx, req.ID)
		if err != nil {
			resp.ScrubError = err.Error()
			status := http.StatusInternalServerError
			if errors.Is(err, store.ErrErasureOpenWithdrawal) {
				status = http.StatusConflict
			}
			writeJSON(w, status, resp)
			return
		}
		resp.Request = res.Request
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleAdminErasureStatus handles GET /v1/admin/accounts/{account_id}/erasure.
func (s *Server) handleAdminErasureStatus(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	accountID, ok := erasureAccountID(w, r)
	if !ok {
		return
	}
	req, outbox, err := s.store.GetAccountErasure(r.Context(), accountID)
	if err != nil {
		writeErasureError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, erasureStatusResponse{Request: req, Outbox: outbox})
}

// handleAdminErasureCancel handles POST /v1/admin/accounts/{account_id}/erasure/cancel.
func (s *Server) handleAdminErasureCancel(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	accountID, ok := erasureAccountID(w, r)
	if !ok {
		return
	}
	req, err := s.store.CancelAccountErasure(r.Context(), accountID, s.adminActor(r), time.Now().UTC())
	if err != nil {
		writeErasureError(w, err)
		return
	}
	s.logger.Info("account erasure canceled", "request_id", req.ID, "account_id", accountID, "actor", req.CanceledBy)
	writeJSON(w, http.StatusOK, erasureRequestResponse{Request: req})
}

func newErasureConfirmToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
