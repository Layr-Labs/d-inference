package releases

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// Latest handles GET /v1/releases/latest.
// Public endpoint — returns the latest active release for a platform.
// Used by install.sh to get the download URL and expected hash.
func (s *Controller) Latest(w http.ResponseWriter, r *http.Request) {
	platform := r.URL.Query().Get("platform")
	if platform == "" {
		platform = DefaultPlatform
	}

	cacheKey := latestReleaseCacheKey(platform)
	if cached, ok := s.cache().Get(cacheKey); ok {
		httpresponse.WriteCachedJSON(w, cached)
		return
	}

	release := s.store().GetLatestRelease(platform)
	if release == nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "no active release for platform "+platform))
		return
	}

	body, err := json.Marshal(release)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to encode release"))
		return
	}
	s.cache().Set(cacheKey, body, time.Minute)
	httpresponse.WriteCachedJSON(w, body)
}
