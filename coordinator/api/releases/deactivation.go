package releases

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Delete handles DELETE /v1/admin/releases.
// Admin-only — deactivates a release version.
func (s *Controller) Delete(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}

	var req struct {
		Version  string `json:"version"`
		Platform string `json:"platform"`
		Force    bool   `json:"force,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Version == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "version is required"))
		return
	}
	if req.Platform == "" {
		req.Platform = DefaultPlatform
	}
	// In-use protection guards BOTH code-identity gates: the legacy
	// self-reported binaryHash allowlist (binaryHashEnforce, default false) and
	// the application-evidence routing gate, which requires active releases
	// whenever a release inventory has ever been published (snapshot.RequiresCodeIdentity()).
	// Gating the precheck on the legacy flag alone would let an ordinary
	// force=false delete deactivate a release that still backs connected
	// providers' evidence — the follow-up sync would clear their evidence and
	// deroute them. force=true remains the explicit override for intentional
	// pulls of a compromised release.
	inUseProtectionActive := s.binaryHashEnforced()
	if snapshot := s.policy().Snapshot(); snapshot != nil && snapshot.RequiresCodeIdentity() {
		inUseProtectionActive = true
	}
	if inUseProtectionActive && !req.Force {
		releases, err := s.store().ListReleasesWithError()
		if err != nil {
			s.logger().Error("admin: release deactivation precheck failed closed", "error", err)
			httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody(
				"release_inventory_unavailable", "failed to read release inventory"))
			return
		}
		if release, ok := findReleaseForDeactivation(releases, req.Version, req.Platform); ok {
			if activeProviders := s.providersWithHash(release.BinaryHash); activeProviders > 0 {
				httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody(
					"release_in_use",
					fmt.Sprintf("release %s/%s binary hash is still used by %d connected provider(s); wait for rollout or set force=true", req.Version, req.Platform, activeProviders),
				))
				return
			}
		}
	}

	if err := s.store().DeleteRelease(req.Version, req.Platform); err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", err.Error()))
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
	if err := s.policy().SyncBinaryHashes(); err != nil {
		s.policy().ConvergeCommittedDeactivation(req.Version, req.Platform, err)
		syncWarnings = append(syncWarnings,
			"release policy synchronization failed; the policy was converged from the committed deactivation and the next successful sync rebuilds from inventory")
	}
	if err := s.policy().SyncRuntimeManifest(); err != nil {
		s.policy().ConvergeCommittedRuntimeDeactivation(req.Version, req.Platform, err)
		syncWarnings = append(syncWarnings,
			"runtime policy synchronization failed; the manifest was converged from the committed deactivation and the next successful sync rebuilds from inventory")
	}
	s.invalidateReleaseCaches(req.Platform)

	s.logger().Info("admin: release deactivated", "version", req.Version, "platform", req.Platform)
	resp := map[string]any{
		"status":   "release_deactivated",
		"version":  req.Version,
		"platform": req.Platform,
	}
	if len(syncWarnings) > 0 {
		resp["warning"] = strings.Join(syncWarnings, "; ")
	}
	httpresponse.WriteJSON(w, http.StatusOK, resp)
}

func findReleaseForDeactivation(releases []store.Release, version, platform string) (store.Release, bool) {
	for _, release := range releases {
		if release.Version == version && release.Platform == platform && release.Active {
			return release, true
		}
	}
	return store.Release{}, false
}
