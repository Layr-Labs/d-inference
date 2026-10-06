package billing

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// handleAdminBaseRewards returns the current base-rewards settlement status for
// the most recently closed epoch: the pool budget, how much has been drawn, the
// reduction factor k, and the per-machine draw rows. Admin-only, read-only.
//
// When the feature flag is off (no engine wired) it returns {"enabled": false}
// so the console can render a disabled state without special-casing a 404.
func (s *Owner) HandleAdminBaseRewards(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}
	if s.baseRewards == nil {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"enabled": false})
		return
	}
	status, err := s.baseRewards.Status(r.Context())
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse(
			"internal_error", "failed to compute base rewards status"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, status)
}
