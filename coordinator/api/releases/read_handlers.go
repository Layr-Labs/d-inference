package releases

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// HandleLatestRelease handles GET /v1/releases/latest.
// Public endpoint — returns the latest active release for a platform.
// Used by install.sh to get the download URL and expected hash.
func (s *Owner) HandleLatestRelease(w http.ResponseWriter, r *http.Request) {
	platform := r.URL.Query().Get("platform")
	if platform == "" {
		platform = defaultReleasePlatform
	}

	cacheKey := latestReleaseCacheKey(platform)
	if cached, ok := s.readCache.Get(cacheKey); ok {
		var release store.Release
		if json.Unmarshal(cached, &release) != nil || !s.appAttestDownloadReady(&release) {
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("release_not_ready", "release authorization is not ready"))
			return
		}
		httpx.WriteCachedJSON(w, cached)
		return
	}

	release := s.store.GetLatestRelease(platform)
	if release == nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "no active release for platform "+platform))
		return
	}

	if !s.appAttestDownloadReady(release) {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("release_not_ready", "release authorization is not ready"))
		return
	}
	body, err := json.Marshal(release)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to encode release"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	httpx.WriteCachedJSON(w, body)
}

// HandleAdminListReleases handles GET /v1/admin/releases.
// Admin-only — returns all releases (active and inactive).
func (s *Owner) HandleAdminListReleases(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}

	releases, err := s.store.ListReleasesWithError()
	if err != nil {
		s.logger.Error("admin: release inventory read failed", "error", err)
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse(
			"release_inventory_unavailable", "failed to read release inventory"))
		return
	}
	if releases == nil {
		releases = []store.Release{}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"releases": releases})
}

// HandleAdminDeleteRelease handles DELETE /v1/admin/releases.
// Admin-only — deactivates a release version.
func (s *Owner) HandleAdminDeleteRelease(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Version  string `json:"version"`
		Platform string `json:"platform"`
		Force    bool   `json:"force,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Version == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "version is required"))
		return
	}
	if req.Platform == "" {
		req.Platform = defaultReleasePlatform
	}
	// In-use protection guards BOTH code-identity gates: the legacy
	// self-reported binaryHash allowlist (binaryHashEnforce, default false) and
	// the application-evidence routing gate, which requires active releases
	// whenever a release inventory has ever been published (snapshot.Required).
	// Gating the precheck on the legacy flag alone would let an ordinary
	// force=false delete deactivate a release that still backs connected
	// providers' evidence — the follow-up sync would clear their evidence and
	// deroute them. force=true remains the explicit override for intentional
	// pulls of a compromised release.
	inUseProtectionActive := s.binaryHashEnforce
	if snapshot := s.releaseTrustPolicy.Load(); snapshot != nil && snapshot.Required {
		inUseProtectionActive = true
	}
	if inUseProtectionActive && !req.Force {
		releases, err := s.store.ListReleasesWithError()
		if err != nil {
			s.logger.Error("admin: release deactivation precheck failed closed", "error", err)
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse(
				"release_inventory_unavailable", "failed to read release inventory"))
			return
		}
		if release, ok := findReleaseForDeactivation(releases, req.Version, req.Platform); ok {
			if activeProviders := s.registry.CountProvidersByBinaryHash(release.BinaryHash); activeProviders > 0 {
				httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse(
					"release_in_use",
					fmt.Sprintf("release %s/%s binary hash is still used by %d connected provider(s); wait for rollout or set force=true", req.Version, req.Platform, activeProviders),
				))
				return
			}
		}
	}

	if err := s.store.DeleteRelease(req.Version, req.Platform); err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", err.Error()))
		return
	}

	// Re-sync known hashes and the runtime manifest after deactivation. The
	// deactivation has already committed, so a post-mutation inventory-read
	// failure must NOT retain a snapshot that still authorizes the deactivated
	// release: there is no background resync, and in a force=true emergency
	// pull of a compromised release the affected providers would keep routing
	// until an admin happened to retry. Mirror the committed-registration
	// convergence — fold the known version/platform deactivation into the
	// retained snapshot, bump the generation, and invalidate/kick the affected
	// providers. The response still surfaces a warning, and the next
	// successful sync rebuilds from the exact inventory.
	var syncWarnings []string
	if err := s.SyncBinaryHashes(); err != nil {
		s.convergeReleasePolicyWithCommittedDeactivation(req.Version, req.Platform, err)
		syncWarnings = append(syncWarnings,
			"release policy synchronization failed; the policy was converged from the committed deactivation and the next successful sync rebuilds from inventory")
	}
	if err := s.SyncRuntimeManifest(); err != nil {
		s.convergeRuntimeManifestWithCommittedDeactivation(req.Version, req.Platform, err)
		syncWarnings = append(syncWarnings,
			"runtime policy synchronization failed; the manifest was converged from the committed deactivation and the next successful sync rebuilds from inventory")
	}
	s.invalidateReleaseCaches(req.Platform)

	s.logger.Info("admin: release deactivated", "version", req.Version, "platform", req.Platform)
	resp := map[string]any{
		"status":   "release_deactivated",
		"version":  req.Version,
		"platform": req.Platform,
	}
	if len(syncWarnings) > 0 {
		resp["warning"] = strings.Join(syncWarnings, "; ")
	}
	httpx.WriteJSON(w, http.StatusOK, resp)
}

func findReleaseForDeactivation(releases []store.Release, version, platform string) (store.Release, bool) {
	for _, release := range releases {
		if release.Version == version && release.Platform == platform && release.Active {
			return release, true
		}
	}
	return store.Release{}, false
}
