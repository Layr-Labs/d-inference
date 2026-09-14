package releases

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// List handles GET /v1/admin/releases.
// Admin-only — returns all releases (active and inactive).
func (s *Controller) List(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}

	releases, err := s.store().ListReleasesWithError()
	if err != nil {
		s.logger().Error("admin: release inventory read failed", "error", err)
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody(
			"release_inventory_unavailable", "failed to read release inventory"))
		return
	}
	if releases == nil {
		releases = []store.Release{}
	}
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"releases": releases})
}
