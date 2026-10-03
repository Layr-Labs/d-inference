package releases

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
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
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid qualification JSON"))
		return false
	}
	if err := d.Decode(&struct{}{}); err != io.EOF {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "expected one JSON object"))
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
func (s *Owner) isBuildAdminAuthorized(w http.ResponseWriter, r *http.Request) bool {
	if access.APIKeyFromContext(r.Context()) != nil {
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("forbidden", "build qualification requires an admin session or admin key"))
		return false
	}
	return s.access.IsAdminAuthorized(w, r)
}

func (s *Owner) HandleAdminAppAttestBuilds(w http.ResponseWriter, r *http.Request) {
	if !s.isBuildAdminAuthorized(w, r) {
		return
	}
	st, ok := store.As[store.AppAttestBuildStore](s.store)
	if !ok {
		httpx.WriteJSON(w, 503, httpx.ErrorResponse("not_configured", "build qualification storage unavailable"))
		return
	}
	if r.Method == http.MethodGet {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		rows, err := st.ListAppAttestBuildQualifications(ctx)
		if err != nil {
			httpx.WriteJSON(w, 503, httpx.ErrorResponse("storage_error", "qualification read failed"))
			return
		}
		httpx.WriteJSON(w, 200, map[string]any{"builds": rows})
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
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}
	if err := body.AppAttestBuildIdentity.Validate(); err != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}
	if strings.TrimSpace(body.Evidence) == "" || len(body.Evidence) > 4096 {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "operator test evidence is required"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), releaseArtifactTimeout)
	defer cancel()
	// Independent operator approval still verifies the exact uploaded bytes.
	// The CI release key cannot call this endpoint or supply its own approver.
	if err := s.verifyReleaseArtifact(ctx, &body.Release); err != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "qualification artifact verification failed: "+err.Error()))
		return
	}
	changed, err := st.QualifyAppAttestBuild(ctx, store.AppAttestBuildQualification{AppAttestBuildIdentity: body.AppAttestBuildIdentity,
		Evidence: body.Evidence, ApprovedBy: buildApprovalActor(r)})
	if err != nil {
		status := http.StatusServiceUnavailable
		if errors.Is(err, store.ErrBuildConflict) {
			status = http.StatusConflict
		}
		httpx.WriteJSON(w, status, httpx.ErrorResponse("qualification_failed", err.Error()))
		return
	}
	if err := s.hooks.AppAttest().RefreshBuildQualifications(ctx); err != nil || !s.hooks.AppAttest().BuildReady(body.AppAttestBuildIdentity) {
		httpx.WriteJSON(w, 503, httpx.ErrorResponse("qualification_pending", "saved qualification is not active locally; retry this request"))
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"qualified": true, "changed": changed, "binary_hash": body.Release.BinaryHash})
}

func (s *Owner) HandleAdminAppAttestBuildRevoke(w http.ResponseWriter, r *http.Request) {
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
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "reason required"))
		return
	}
	binary, err := NormalizeSHA256Hex(body.BinaryHash, "binary_hash")
	if err != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}
	st, ok := store.As[store.AppAttestBuildStore](s.store)
	if !ok {
		httpx.WriteJSON(w, 503, httpx.ErrorResponse("not_configured", "build qualification storage unavailable"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	changed, err := st.RevokeAppAttestBuild(ctx, binary, buildApprovalActor(r), body.Reason)
	if err != nil {
		httpx.WriteJSON(w, 503, httpx.ErrorResponse("storage_error", "build revocation failed"))
		return
	}
	s.hooks.AppAttest().FenceBuild(binary)
	s.invalidateReleaseCaches(defaultReleasePlatform)
	httpx.WriteJSON(w, 200, map[string]any{"revoked": true, "changed": changed, "max_propagation_seconds": 30})
}

func (s *Owner) requiresAppAttestPublication() bool {
	return s.appAttestServing()
}

// Other coordinator instances observe active-catalog changes without a restart.
// Do not increment policy generations for unchanged five-second poll results.
func (s *Owner) RefreshAppAttestReleaseCatalog() error {
	releases, err := s.store.ListReleasesWithError()
	if err != nil {
		return err
	}
	next := &releaseTrustPolicySnapshot{ByBinaryHash: make(map[string][]approvedReleasePolicy)}
	for _, r := range releases {
		if !r.Active {
			continue
		}
		hash, err := NormalizeSHA256Hex(r.BinaryHash, "binary_hash")
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

func (s *Owner) appAttestDownloadReady(release *store.Release) bool {
	if !s.requiresAppAttestPublication() {
		return true
	}
	return s.hooks.AppAttest().ReleaseReady(*release) && releaseEvidenceStillApproved(s.releaseTrustPolicy.Load(), registry.ApplicationEvidence{
		Version: release.Version, Platform: release.Platform, Backend: release.Backend, BinaryHash: release.BinaryHash, MetallibHash: release.MetallibHash})
}

func (s *Owner) appAttestVersionDownloadReady(v types.VersionResponse) bool {
	return s.appAttestDownloadReady(&store.Release{Version: v.Version, Platform: v.Platform, Backend: v.Backend,
		BinaryHash: v.BinaryHash, BundleHash: v.BundleHash, MetallibHash: v.MetallibHash, URL: v.DownloadURL})
}
