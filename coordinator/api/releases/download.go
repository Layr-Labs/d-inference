package releases

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// HandleVersion returns the latest provider CLI version and download URL.
// Providers call GET /api/version to check if they need to update.
// If a release is registered in the store, uses that. Otherwise falls back
// to the hardcoded s.hooks.LatestProviderVersion().
func (s *Owner) HandleVersion(w http.ResponseWriter, r *http.Request) {
	if cached, ok := s.readCache.Get(apiVersionCacheKey); ok {
		var version types.VersionResponse
		if json.Unmarshal(cached, &version) != nil || !s.appAttestVersionDownloadReady(version) {
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("release_not_ready", "release authorization is not ready"))
			return
		}
		httpx.WriteCachedJSON(w, cached)
		return
	}

	var resp types.VersionResponse
	// Try release table first.
	if release := s.store.GetLatestRelease(defaultReleasePlatform); release != nil {
		if !s.appAttestDownloadReady(release) {
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("release_not_ready", "release authorization is not ready"))
			return
		}
		resp = types.VersionResponse{
			Version:      release.Version,
			Platform:     release.Platform,
			Backend:      release.Backend,
			DownloadURL:  release.URL,
			BinaryHash:   release.BinaryHash,
			BundleHash:   release.BundleHash,
			MetallibHash: release.MetallibHash,
			Changelog:    release.Changelog,
		}
	} else {
		if s.requiresAppAttestPublication() {
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("release_not_ready", "no authorized provider release available"))
			return
		}
		// Fallback to hardcoded version + coordinator download.
		scheme := "https"
		if r.TLS == nil && !strings.Contains(r.Host, "darkbloom.dev") {
			scheme = "http"
		}
		downloadURL := fmt.Sprintf("%s://%s/dl/eigeninference-bundle-macos-arm64.tar.gz", scheme, r.Host)
		resp = types.VersionResponse{
			Version:     s.hooks.LatestProviderVersion(),
			DownloadURL: downloadURL,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to encode version"))
		return
	}
	s.readCache.Set(apiVersionCacheKey, body, time.Minute)
	httpx.WriteCachedJSON(w, body)
}
