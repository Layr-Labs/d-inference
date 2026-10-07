package releases

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	maxReleaseRegisterBodyBytes = 64 * 1024
	maxReleaseArtifactBytes     = 2 << 30 // 2 GiB
	maxReleaseProviderBinBytes  = 512 << 20
	releaseArtifactTimeout      = 2 * time.Minute
)

var (
	releaseVersionPattern      = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$`)
	releasePlatformPattern     = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	releaseTemplateNamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)

type registerReleaseRequest struct {
	RequireAppAttestQualification bool   `json:"require_app_attest_qualification,omitempty"`
	CodeDirectoryHash             string `json:"code_directory_hash,omitempty"`
	SourceCommit                  string `json:"source_commit,omitempty"`
	CIRunID                       string `json:"ci_run_id,omitempty"`
	Version                       string `json:"version"`
	Platform                      string `json:"platform"`
	Backend                       string `json:"backend,omitempty"`
	BinaryHash                    string `json:"binary_hash"`
	BundleHash                    string `json:"bundle_hash"`
	MetallibHash                  string `json:"metallib_hash,omitempty"`
	TemplateHashes                string `json:"template_hashes,omitempty"`
	URL                           string `json:"url"`
	Changelog                     string `json:"changelog"`
}

func (req registerReleaseRequest) toRelease() store.Release {
	return store.Release{
		Version:        req.Version,
		Platform:       req.Platform,
		Backend:        req.Backend,
		BinaryHash:     req.BinaryHash,
		BundleHash:     req.BundleHash,
		MetallibHash:   req.MetallibHash,
		TemplateHashes: req.TemplateHashes,
		URL:            req.URL,
		Changelog:      req.Changelog,
	}
}

// HandleRegisterRelease handles POST /v1/releases.
// Called by GitHub Actions to register a new provider binary release.
// Authenticated with a scoped release key (NOT admin credentials).
func (s *Owner) HandleRegisterRelease(w http.ResponseWriter, r *http.Request) {
	// Verify scoped release key.
	token := access.ExtractBearerToken(r)
	if !s.access.ReleaseKeyAuthorized(token) {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("unauthorized", "invalid release key"))
		return
	}

	var req registerReleaseRequest
	r.Body = http.MaxBytesReader(w, r.Body, maxReleaseRegisterBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: multiple JSON values"))
		return
	}
	release := req.toRelease()
	if release.Platform == "" {
		release.Platform = "macos-arm64" // default
	}

	if err := s.validateReleaseMetadata(&release); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}

	if s.r2CDNURL == "" {
		s.logger.Error("release: artifact verification unavailable because R2 CDN URL is not configured",
			"version", release.Version,
			"platform", release.Platform,
		)
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("not_configured", "release artifact verification requires R2 CDN URL"))
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), releaseArtifactTimeout)
	defer cancel()
	if err := s.verifyReleaseArtifact(ctx, &release); err != nil {
		s.logger.Warn("release: artifact verification failed",
			"version", release.Version,
			"platform", release.Platform,
			"error", err,
		)
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "release artifact verification failed: "+err.Error()))
		return
	}

	saveErr := s.persistReleaseForPublication(ctx, release, req)
	if errors.Is(saveErr, errBuildQualificationUnavailable) {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("qualification_unavailable", "qualification refresh failed"))
		return
	}
	if errors.Is(saveErr, store.ErrBuildNotQualified) || errors.Is(saveErr, store.ErrBuildConflict) {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("app_attest_qualification_required", "approve the exact signed artifact via /v1/admin/app-attest/builds, then retry publication: "+saveErr.Error()))
		return
	}
	if err := saveErr; err != nil {
		s.logger.Error("release: register failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to save release"))
		return
	}

	// Auto-update known binary hashes and runtime manifest from all active
	// releases. The release row has already committed and GET /v1/releases/latest
	// serves straight from the store, so a transient inventory-read failure must
	// not strand the policy on the pre-registration snapshot: providers would
	// install a release the policy can never authorize and — with no background
	// resync — stay unroutable indefinitely. When the post-mutation re-read
	// fails, converge the in-memory policy from the committed mutation itself;
	// registration stays atomic and successful for the caller, and the next
	// successful sync rebuilds from the full inventory.
	if err := s.SyncBinaryHashes(); err != nil {
		s.convergeReleasePolicyWithCommittedRelease(&release, err)
	}
	if err := s.SyncRuntimeManifest(); err != nil {
		s.convergeRuntimeManifestWithCommittedRelease(&release, err)
	}

	// Invalidate cached version/manifest/release responses so providers and
	// install.sh see the new release on the next request instead of waiting
	// out the TTL.
	s.invalidateReleaseCaches(release.Platform)

	s.logger.Info("release registered",
		"version", release.Version,
		"platform", release.Platform,
		"binary_hash", release.BinaryHash[:min(16, len(release.BinaryHash))]+"...",
	)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"status":  "release_registered",
		"release": release,
	})
}
