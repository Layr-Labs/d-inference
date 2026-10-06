package erasure

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
	// AccountID must repeat the path's account ID, so an account without an
	// email is still confirmed by something the admin typed.
	AccountID       string   `json:"account_id"`
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
	Request        *store.ErasureRequest        `json:"request"`
	Outbox         []store.ErasureOutboxItem    `json:"outbox"`
	RefusedCredits []store.ErasureRefusedCredit `json:"refused_credits"`
}

// adminActor names the admin who acted: the admin key, or the account of a
// Privy admin. It never holds an email.
func (s *Owner) adminActor(r *http.Request) string {
	if s.access.AdminKeyAuthorized(access.ExtractBearerToken(r)) {
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
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "account or erasure request not found"))
	case errors.Is(err, store.ErrErasureConfirmToken):
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("invalid_confirm_token", "confirm token is invalid or expired; run the plan again"))
	case errors.Is(err, store.ErrErasureWalletMismatch):
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("wallet_mismatch", "wallet_addresses differ from the list in the plan; run the plan again", httpx.WithParam("wallet_addresses")))
	case errors.Is(err, store.ErrErasureEmailMismatch):
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("email_mismatch", "email does not match the account email shown in the plan", httpx.WithParam("email")))
	case errors.Is(err, store.ErrErasureOpenWithdrawal):
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("open_withdrawal", "the account has a withdrawal that is not in a terminal state"))
	case errors.Is(err, store.ErrErasureConflict):
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("erasure_conflict", "the erasure request is not in a state that allows this step"))
	default:
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "account erasure failed"))
	}
}

func erasureAccountID(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := strings.TrimSpace(r.PathValue("account_id"))
	if id == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "account_id is required", httpx.WithParam("account_id")))
		return "", false
	}
	return id, true
}

// HandlePlan handles POST /v1/admin/accounts/{account_id}/erasure/plan.
// It returns the dry run and a confirm token, and changes no account data.
func (s *Owner) HandlePlan(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}
	accountID, ok := erasureAccountID(w, r)
	if !ok {
		return
	}
	var body erasurePlanBody
	r.Body = http.MaxBytesReader(w, r.Body, s.maxBodyBytes)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		httpx.WriteJSON(w, http.StatusRequestEntityTooLarge, httpx.ErrorResponse("invalid_request_error", "request body too large"))
		return
	}
	if len(strings.TrimSpace(string(raw))) > 0 {
		if err := json.Unmarshal(raw, &body); err != nil {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON"))
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
	req, err := s.store.SaveErasurePlan(ctx, accountID, s.adminActor(r), plan.ErasureCounts, body.WalletAddresses, token, expires)
	if errors.Is(err, store.ErrNotFound) {
		// The user row exists (the plan read it) but is no longer live.
		err = store.ErrErasureConflict
	}
	if err != nil {
		writeErasureError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, erasurePlanResponse{
		ErasurePlan: plan, RequestID: req.ID, ConfirmToken: token, ConfirmExpiresAt: expires,
		GraceSeconds: int64(s.grace / time.Second),
	})
}

// HandleRequest handles POST /v1/admin/accounts/{account_id}/erasure.
// It soft deletes the account (revoking its keys and provider tokens),
// disconnects its providers, and with force=true scrubs at once.
func (s *Owner) HandleRequest(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}
	accountID, ok := erasureAccountID(w, r)
	if !ok {
		return
	}
	var body erasureConfirmBody
	if !httpx.DecodeCappedJSON(w, r, s.maxBodyBytes, &body) {
		return
	}
	if body.ConfirmToken == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "confirm_token is required", httpx.WithParam("confirm_token")))
		return
	}
	if body.AccountID != accountID {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "account_id must repeat the account in the path", httpx.WithParam("account_id")))
		return
	}
	ctx := r.Context()
	req, err := s.store.RequestAccountErasure(ctx, store.ErasureConfirm{
		AccountID: accountID, ConfirmToken: body.ConfirmToken, Email: body.Email,
		Actor: s.adminActor(r), Reason: body.Reason, WalletAddresses: body.WalletAddresses,
		Now: time.Now().UTC(), Grace: s.grace,
	})
	if err != nil {
		writeErasureError(w, err)
		return
	}
	// The tokens are revoked in the commit above, so a provider that
	// reconnects after this disconnect comes back unlinked.
	s.access.InvalidateAllAPIKeyCache()
	disconnected := s.hooks.DisconnectAccount(accountID)
	s.logger.Info("account erasure requested", "request_id", req.ID, "account_id", accountID,
		"actor", req.Actor, "providers_disconnected", disconnected, "force", body.Force)

	resp := erasureRequestResponse{Request: req}
	if body.Force {
		res, err := s.scrub(ctx, req.ID)
		if err != nil {
			resp.ScrubError = err.Error()
			status := http.StatusInternalServerError
			if errors.Is(err, store.ErrErasureOpenWithdrawal) {
				status = http.StatusConflict
			}
			httpx.WriteJSON(w, status, resp)
			return
		}
		resp.Request = res.Request
	}
	httpx.WriteJSON(w, http.StatusOK, resp)
}

// HandleStatus handles GET /v1/admin/accounts/{account_id}/erasure.
func (s *Owner) HandleStatus(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
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
	refused, err := s.store.ListErasureRefusedCredits(r.Context(), accountID)
	if err != nil {
		writeErasureError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, erasureStatusResponse{Request: req, Outbox: outbox, RefusedCredits: refused})
}

// HandleCancel handles POST /v1/admin/accounts/{account_id}/erasure/cancel.
func (s *Owner) HandleCancel(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
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
	httpx.WriteJSON(w, http.StatusOK, erasureRequestResponse{Request: req})
}

func newErasureConfirmToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
