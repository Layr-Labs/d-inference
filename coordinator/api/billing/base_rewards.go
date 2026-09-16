package billing

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// AdminBaseRewards returns the current base-rewards settlement status for
// the most recently closed epoch: the pool budget, how much has been drawn, the
// reduction factor k, and the per-machine draw rows. Admin-only, read-only.
//
// When the feature flag is off (no engine wired) it returns {"enabled": false}
// so the console can render a disabled state without special-casing a 404.
func (s *Controller) AdminBaseRewards(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}
	if s.baseRewards() == nil {
		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"enabled": false})
		return
	}
	status, err := s.baseRewards().Status(r.Context())
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody(
			"internal_error", "failed to compute base rewards status"))
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, status)
}
