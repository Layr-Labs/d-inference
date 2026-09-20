package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func decodeBuildRequest(w http.ResponseWriter, r *http.Request, body any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxReleaseRegisterBodyBytes)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(body); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid qualification JSON"))
		return false
	}
	if err := d.Decode(&struct{}{}); err != io.EOF {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "expected one JSON object"))
		return false
	}
	return true
}

func buildApprovalActor(r *http.Request) string {
	if u := auth.UserFromContext(r.Context()); u != nil {
		return u.AccountID
	}
	return "admin-key"
}

// requireAuth establishes the Privy/admin-key identity at the route boundary.
// An admin-owned inference key or provider token must not inherit the owner's
// ability to approve executable builds merely because it resolves to that user.
func (s *Server) isBuildAdminAuthorized(w http.ResponseWriter, r *http.Request) bool {
	if r.Context().Value(ctxKeyAPIKey) != nil {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "build qualification requires an admin session or admin key"))
		return false
	}
	return s.isAdminAuthorized(w, r)
}

func (s *Server) handleAdminAppAttestBuilds(w http.ResponseWriter, r *http.Request) {
	if !s.isBuildAdminAuthorized(w, r) {
		return
	}
	st, ok := store.As[store.AppAttestBuildStore](s.store)
	if !ok {
		writeJSON(w, 503, errorResponse("not_configured", "build qualification storage unavailable"))
		return
	}
	if r.Method == http.MethodGet {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		rows, err := st.ListAppAttestBuildQualifications(ctx)
		if err != nil {
			writeJSON(w, 503, errorResponse("storage_error", "qualification read failed"))
			return
		}
		writeJSON(w, 200, map[string]any{"builds": rows})
		return
	}
	var body struct {
		store.AppAttestBuildIdentity
		Evidence string `json:"evidence"`
	}
	if !decodeBuildRequest(w, r, &body) {
		return
	}
	if err := s.validateReleaseMetadata(&body.Release); err != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if err := body.AppAttestBuildIdentity.Validate(); err != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if strings.TrimSpace(body.Evidence) == "" || len(body.Evidence) > 4096 {
		writeJSON(w, 400, errorResponse("invalid_request_error", "operator test evidence is required"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), releaseArtifactTimeout)
	defer cancel()
	// Independent operator approval still verifies the exact uploaded bytes.
	// The CI release key cannot call this endpoint or supply its own approver.
	if err := s.verifyReleaseArtifact(ctx, &body.Release); err != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", "qualification artifact verification failed: "+err.Error()))
		return
	}
	changed, err := st.QualifyAppAttestBuild(ctx, store.AppAttestBuildQualification{AppAttestBuildIdentity: body.AppAttestBuildIdentity,
		Evidence: body.Evidence, ApprovedBy: buildApprovalActor(r)})
	if err != nil {
		status := http.StatusServiceUnavailable
		if errors.Is(err, store.ErrBuildConflict) {
			status = http.StatusConflict
		}
		writeJSON(w, status, errorResponse("qualification_failed", err.Error()))
		return
	}
	if err := s.appAttestFeature().RefreshBuildQualifications(ctx); err != nil || !s.appAttestFeature().BuildReady(body.AppAttestBuildIdentity) {
		writeJSON(w, 503, errorResponse("qualification_pending", "saved qualification is not active locally; retry this request"))
		return
	}
	writeJSON(w, 200, map[string]any{"qualified": true, "changed": changed, "binary_hash": body.Release.BinaryHash})
}

func (s *Server) handleAdminAppAttestBuildRevoke(w http.ResponseWriter, r *http.Request) {
	if !s.isBuildAdminAuthorized(w, r) {
		return
	}
	var body struct {
		BinaryHash string `json:"binary_hash"`
		Reason     string `json:"reason"`
	}
	if !decodeBuildRequest(w, r, &body) {
		return
	}
	if strings.TrimSpace(body.Reason) == "" || len(body.Reason) > 4096 {
		writeJSON(w, 400, errorResponse("invalid_request_error", "reason required"))
		return
	}
	binary, err := normalizeSHA256Hex(body.BinaryHash, "binary_hash")
	if err != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", err.Error()))
		return
	}
	st, ok := store.As[store.AppAttestBuildStore](s.store)
	if !ok {
		writeJSON(w, 503, errorResponse("not_configured", "build qualification storage unavailable"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	changed, err := st.RevokeAppAttestBuild(ctx, binary, buildApprovalActor(r), body.Reason)
	if err != nil {
		writeJSON(w, 503, errorResponse("storage_error", "build revocation failed"))
		return
	}
	s.appAttestFeature().FenceBuild(binary)
	s.invalidateReleaseCaches(defaultReleasePlatform)
	writeJSON(w, 200, map[string]any{"revoked": true, "changed": changed, "max_propagation_seconds": 30})
}

func (s *Server) requiresAppAttestPublication() bool {
	return s.appAttestShadow.ServingEnabled && s.appAttestShadow.Environment == "production"
}

// Other coordinator instances observe active-catalog changes without a restart.
// Do not increment policy generations for unchanged five-second poll results.
func (s *Server) refreshAppAttestReleaseCatalog() error {
	releases, err := s.store.ListReleasesWithError()
	if err != nil {
		return err
	}
	next := &releaseTrustPolicySnapshot{ByBinaryHash: make(map[string][]approvedReleasePolicy)}
	for _, r := range releases {
		if !r.Active {
			continue
		}
		hash, err := normalizeSHA256Hex(r.BinaryHash, "binary_hash")
		if err == nil {
			next.addRelease(&r, hash)
		}
	}
	old := s.releaseTrustPolicy.Load()
	if old == nil || !reflect.DeepEqual(old.ByBinaryHash, next.ByBinaryHash) {
		s.appAttestRuntimeRefreshPending.Store(true)
		if err := s.SyncBinaryHashes(); err != nil {
			return err
		}
	} else if !s.appAttestRuntimeRefreshPending.Load() {
		return nil
	}
	if err := s.SyncRuntimeManifest(); err != nil {
		return err
	}
	s.appAttestRuntimeRefreshPending.Store(false)
	s.invalidateReleaseCaches(defaultReleasePlatform)
	return nil
}

func (s *Server) appAttestDownloadReady(release *store.Release) bool {
	if !s.requiresAppAttestPublication() {
		return true
	}
	return s.appAttestFeature().ReleaseReady(*release) && releaseEvidenceStillApproved(s.releaseTrustPolicy.Load(), registry.ApplicationEvidence{
		Version: release.Version, Platform: release.Platform, Backend: release.Backend, BinaryHash: release.BinaryHash, MetallibHash: release.MetallibHash})
}

func (s *Server) appAttestVersionDownloadReady(v types.VersionResponse) bool {
	return s.appAttestDownloadReady(&store.Release{Version: v.Version, Platform: v.Platform, Backend: v.Backend,
		BinaryHash: v.BinaryHash, BundleHash: v.BundleHash, MetallibHash: v.MetallibHash, URL: v.DownloadURL})
}
