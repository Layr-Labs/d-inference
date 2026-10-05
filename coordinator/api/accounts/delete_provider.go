package accounts

import (
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// handleDeleteMyProvider handles DELETE /v1/me/providers/{id}.
//
// Removes an offline/retired machine's persisted record(s) so it stops
// reappearing in GET /v1/me/providers. Ownership-checked: the caller's account
// must own the record. A currently-connected machine is refused with 409 (it
// would just re-register). Billing/uptime history (earnings, usage, sessions)
// is preserved by the store.
func (s *Owner) HandleDeleteMyProvider(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return // 401 already written
	}

	providerID := strings.TrimSpace(r.PathValue("id"))
	if providerID == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "missing provider id"))
		return
	}

	ctx := r.Context()

	// The public route accepts only the opaque provider session id. Resolve the
	// stable hardware identity internally so serials never enter URLs or API
	// payloads while reconnect rows are still removed together.
	rec, err := s.store.GetProviderRecord(ctx, providerID)
	if err != nil || rec == nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "machine not found"))
		return
	}
	if rec.AccountID != user.AccountID {
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("forbidden", "you do not own this machine"))
		return
	}

	stableIdentity := rec.ID
	if rec.SerialNumber != "" {
		stableIdentity = rec.SerialNumber
	}

	// Refuse if the machine is currently connected — it would re-register and
	// the card would return.
	if s.registry.RemoveProviderBySerial(stableIdentity, false) {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("conflict", "machine is currently online — stop it before removing"))
		return
	}

	n, err := s.store.DeleteProvidersBySerial(ctx, user.AccountID, stableIdentity)
	if err != nil {
		s.logger.Error("delete provider failed", "account_id", user.AccountID, "provider_id", providerID, "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to remove machine"))
		return
	}
	if n == 0 {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "machine not found"))
		return
	}

	// Best-effort: drop any lingering in-memory entry so an evict-race can't
	// re-persist the record we just removed.
	s.registry.RemoveProviderBySerial(stableIdentity, true)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"deleted":      true,
		"rows_removed": n,
	})
}
