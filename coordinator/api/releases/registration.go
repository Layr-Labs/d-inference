package releases

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"io"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type registerReleaseRequest struct {
	Version        string `json:"version"`
	Platform       string `json:"platform"`
	Backend        string `json:"backend,omitempty"`
	BinaryHash     string `json:"binary_hash"`
	BundleHash     string `json:"bundle_hash"`
	MetallibHash   string `json:"metallib_hash,omitempty"`
	PythonHash     string `json:"python_hash,omitempty"`
	RuntimeHash    string `json:"runtime_hash,omitempty"`
	TemplateHashes string `json:"template_hashes,omitempty"`
	URL            string `json:"url"`
	Changelog      string `json:"changelog"`
}

func (req registerReleaseRequest) toRelease() store.Release {
	return store.Release{
		Version:        req.Version,
		Platform:       req.Platform,
		Backend:        req.Backend,
		BinaryHash:     req.BinaryHash,
		BundleHash:     req.BundleHash,
		MetallibHash:   req.MetallibHash,
		PythonHash:     req.PythonHash,
		RuntimeHash:    req.RuntimeHash,
		TemplateHashes: req.TemplateHashes,
		URL:            req.URL,
		Changelog:      req.Changelog,
	}
}

// Register handles POST /v1/releases.
// Called by GitHub Actions to register a new provider binary release.
// Authenticated with a scoped release key (NOT admin credentials).
func (s *Controller) Register(w http.ResponseWriter, r *http.Request) {
	// Verify scoped release key.
	token := s.bearerToken(r)
	if !s.authorizedReleaseKey(token) {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("unauthorized", "invalid release key"))
		return
	}

	var req registerReleaseRequest
	r.Body = http.MaxBytesReader(w, r.Body, maxReleaseRegisterBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: multiple JSON values"))
		return
	}
	release := req.toRelease()
	if release.Platform == "" {
		release.Platform = "macos-arm64" // default
	}

	if err := s.validateReleaseMetadata(&release); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", err.Error()))
		return
	}

	if s.cdnURL() == "" {
		s.logger().Error("release: artifact verification unavailable because R2 CDN URL is not configured",
			"version", release.Version,
			"platform", release.Platform,
		)
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("not_configured", "release artifact verification requires R2 CDN URL"))
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), releaseArtifactTimeout)
	defer cancel()
	if err := s.verifyReleaseArtifact(ctx, &release); err != nil {
		s.logger().Warn("release: artifact verification failed",
			"version", release.Version,
			"platform", release.Platform,
			"error", err,
		)
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "release artifact verification failed: "+err.Error()))
		return
	}

	if err := s.store().SetRelease(&release); err != nil {
		s.logger().Error("release: register failed", "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to save release"))
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
	if err := s.policy().SyncBinaryHashes(); err != nil {
		s.policy().ConvergeCommittedRelease(&release, err)
	}
	if err := s.policy().SyncRuntimeManifest(); err != nil {
		s.policy().ConvergeCommittedRuntimeRelease(&release, err)
	}

	// Invalidate cached version/manifest/release responses so providers and
	// install.sh see the new release on the next request instead of waiting
	// out the TTL.
	s.invalidateReleaseCaches(release.Platform)

	s.logger().Info("release registered",
		"version", release.Version,
		"platform", release.Platform,
		"binary_hash", release.BinaryHash[:min(16, len(release.BinaryHash))]+"...",
	)

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"status":  "release_registered",
		"release": release,
	})
}

func (s *Controller) authorizedReleaseKey(token string) bool {
	if s.releaseKey() == "" || token == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(s.releaseKey())) == 1
}
