package api

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/store"
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
	Version        string `json:"version"`
	Platform       string `json:"platform"`
	BinaryHash     string `json:"binary_hash"`
	BundleHash     string `json:"bundle_hash"`
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
		BinaryHash:     req.BinaryHash,
		BundleHash:     req.BundleHash,
		PythonHash:     req.PythonHash,
		RuntimeHash:    req.RuntimeHash,
		TemplateHashes: req.TemplateHashes,
		URL:            req.URL,
		Changelog:      req.Changelog,
	}
}

// handleRegisterRelease handles POST /v1/releases.
// Called by GitHub Actions to register a new provider binary release.
// Authenticated with a scoped release key (NOT admin credentials).
func (s *Server) handleRegisterRelease(w http.ResponseWriter, r *http.Request) {
	// Verify scoped release key.
	token := extractBearerToken(r)
	if !s.releaseKeyAuthorized(token) {
		writeJSON(w, http.StatusUnauthorized, errorResponse("unauthorized", "invalid release key"))
		return
	}

	var req registerReleaseRequest
	r.Body = http.MaxBytesReader(w, r.Body, maxReleaseRegisterBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: multiple JSON values"))
		return
	}
	release := req.toRelease()
	if release.Platform == "" {
		release.Platform = "macos-arm64" // default
	}

	if err := s.validateReleaseMetadata(&release); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}

	if s.r2CDNURL == "" {
		s.logger.Error("release: artifact verification unavailable because R2 CDN URL is not configured",
			"version", release.Version,
			"platform", release.Platform,
		)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("not_configured", "release artifact verification requires R2 CDN URL"))
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
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "release artifact verification failed: "+err.Error()))
		return
	}

	if err := s.store.SetRelease(&release); err != nil {
		s.logger.Error("release: register failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to save release"))
		return
	}

	// Auto-update known binary hashes and runtime manifest from all active releases.
	s.SyncBinaryHashes()
	s.SyncRuntimeManifest()

	// Invalidate cached version/manifest/release responses so providers and
	// install.sh see the new release on the next request instead of waiting
	// out the TTL.
	s.readCache.Invalidate("api_version:v1")
	s.readCache.Invalidate("runtime_manifest:v1")
	s.readCache.Invalidate("latest_release:v1")

	s.logger.Info("release registered",
		"version", release.Version,
		"platform", release.Platform,
		"binary_hash", release.BinaryHash[:min(16, len(release.BinaryHash))]+"...",
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "release_registered",
		"release": release,
	})
}

func (s *Server) releaseKeyAuthorized(token string) bool {
	if s.releaseKey == "" || token == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(s.releaseKey)) == 1
}

func (s *Server) validateReleaseMetadata(release *store.Release) error {
	release.Version = strings.TrimSpace(release.Version)
	release.Platform = strings.TrimSpace(release.Platform)
	release.BinaryHash = strings.TrimSpace(release.BinaryHash)
	release.BundleHash = strings.TrimSpace(release.BundleHash)
	release.PythonHash = strings.TrimSpace(release.PythonHash)
	release.RuntimeHash = strings.TrimSpace(release.RuntimeHash)
	release.TemplateHashes = strings.TrimSpace(release.TemplateHashes)
	release.URL = strings.TrimSpace(release.URL)

	if release.Version == "" {
		return fmt.Errorf("version is required")
	}
	if !releaseVersionPattern.MatchString(release.Version) {
		return fmt.Errorf("version must be semver, e.g. 1.2.3 or 1.2.3-dev.1")
	}
	if release.Platform == "" {
		return fmt.Errorf("platform is required")
	}
	if !releasePlatformPattern.MatchString(release.Platform) {
		return fmt.Errorf("platform contains invalid characters")
	}

	var err error
	if release.BinaryHash, err = normalizeSHA256Hex(release.BinaryHash, "binary_hash"); err != nil {
		return err
	}
	if release.BundleHash, err = normalizeSHA256Hex(release.BundleHash, "bundle_hash"); err != nil {
		return err
	}
	if release.PythonHash != "" {
		if release.PythonHash, err = normalizeSHA256Hex(release.PythonHash, "python_hash"); err != nil {
			return err
		}
	}
	if release.RuntimeHash != "" {
		if release.RuntimeHash, err = normalizeSHA256Hex(release.RuntimeHash, "runtime_hash"); err != nil {
			return err
		}
	}
	if release.TemplateHashes != "" {
		if release.TemplateHashes, err = normalizeTemplateHashes(release.TemplateHashes); err != nil {
			return err
		}
	}
	if release.URL == "" {
		return fmt.Errorf("url is required")
	}
	if s.r2CDNURL != "" {
		if _, err := s.trustedReleaseArtifactURL(release); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) trustedReleaseArtifactURL(release *store.Release) (*url.URL, error) {
	expectedURL, err := expectedReleaseArtifactURL(s.r2CDNURL, release.Version, release.Platform)
	if err != nil {
		return nil, err
	}
	if !sameReleaseArtifactURL(release.URL, expectedURL) {
		return nil, fmt.Errorf("url must match configured release artifact path")
	}
	parsed, err := url.Parse(expectedURL)
	if err != nil {
		return nil, fmt.Errorf("configured release artifact URL is invalid")
	}
	return parsed, nil
}

func expectedReleaseArtifactURL(baseURL, version, platform string) (string, error) {
	version = strings.TrimSpace(version)
	platform = strings.TrimSpace(platform)
	if !releaseVersionPattern.MatchString(version) {
		return "", fmt.Errorf("version must be semver, e.g. 1.2.3 or 1.2.3-dev.1")
	}
	if !releasePlatformPattern.MatchString(platform) {
		return "", fmt.Errorf("platform contains invalid characters")
	}

	u, err := url.Parse(strings.TrimSpace(baseURL))
	if err != nil {
		return "", fmt.Errorf("configured R2 CDN URL is invalid")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("configured R2 CDN URL must not include credentials, query, or fragment")
	}
	if u.Host == "" {
		return "", fmt.Errorf("configured R2 CDN URL must include a host")
	}
	if u.Scheme != "https" && u.Scheme != "http" {
		return "", fmt.Errorf("configured R2 CDN URL must be absolute")
	}
	if u.Scheme == "http" && !isLoopbackHost(u.Hostname()) {
		return "", fmt.Errorf("configured R2 CDN URL must use https")
	}
	u.Path = path.Join(u.Path, "releases", "v"+version, "eigeninference-bundle-"+platform+".tar.gz")
	u.RawQuery = ""
	u.Fragment = ""
	return u.String(), nil
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func sameReleaseArtifactURL(actual, expected string) bool {
	actualURL, err := url.Parse(strings.TrimSpace(actual))
	if err != nil {
		return false
	}
	expectedURL, err := url.Parse(expected)
	if err != nil {
		return false
	}
	if actualURL.User != nil || expectedURL.User != nil {
		return false
	}
	return strings.EqualFold(actualURL.Scheme, expectedURL.Scheme) &&
		strings.EqualFold(actualURL.Host, expectedURL.Host) &&
		path.Clean(actualURL.EscapedPath()) == path.Clean(expectedURL.EscapedPath()) &&
		actualURL.RawQuery == "" &&
		actualURL.Fragment == ""
}

func normalizeSHA256Hex(value, field string) (string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	if len(value) != sha256.Size*2 {
		return "", fmt.Errorf("%s must be a 64-character SHA-256 hex digest", field)
	}
	if _, err := hex.DecodeString(value); err != nil {
		return "", fmt.Errorf("%s must be a valid SHA-256 hex digest", field)
	}
	return value, nil
}

func normalizeTemplateHashes(raw string) (string, error) {
	entries := strings.Split(raw, ",")
	normalized := make([]string, 0, len(entries))
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		name, hash, ok := strings.Cut(entry, "=")
		if !ok {
			return "", fmt.Errorf("template_hashes entries must be name=sha256")
		}
		name = strings.TrimSpace(name)
		if name == "" || !releaseTemplateNamePattern.MatchString(name) {
			return "", fmt.Errorf("template_hashes contains an invalid template name")
		}
		hash, err := normalizeSHA256Hex(hash, "template_hashes")
		if err != nil {
			return "", err
		}
		normalized = append(normalized, name+"="+hash)
	}
	return strings.Join(normalized, ","), nil
}

func (s *Server) verifyReleaseArtifact(ctx context.Context, release *store.Release) error {
	downloadURL, err := s.trustedReleaseArtifactURL(release)
	if err != nil {
		return err
	}
	req := &http.Request{
		Method: http.MethodGet,
		URL:    downloadURL,
		Header: make(http.Header),
	}
	req = req.WithContext(ctx)

	client := &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download bundle: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download bundle returned status %d", resp.StatusCode)
	}

	tmp, err := os.CreateTemp("", "darkbloom-release-*.tar.gz")
	if err != nil {
		return fmt.Errorf("create temp bundle: %w", err)
	}
	defer func() {
		tmp.Close()
		os.Remove(tmp.Name())
	}()

	bundleHash := sha256.New()
	limited := io.LimitReader(resp.Body, maxReleaseArtifactBytes+1)
	n, err := io.Copy(io.MultiWriter(tmp, bundleHash), limited)
	if err != nil {
		return fmt.Errorf("read bundle: %w", err)
	}
	if n > maxReleaseArtifactBytes {
		return fmt.Errorf("bundle exceeds maximum size")
	}
	actualBundleHash := hex.EncodeToString(bundleHash.Sum(nil))
	if actualBundleHash != release.BundleHash {
		return fmt.Errorf("bundle_hash does not match release artifact")
	}

	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("rewind bundle: %w", err)
	}

	gz, err := gzip.NewReader(tmp)
	if err != nil {
		return fmt.Errorf("open bundle gzip: %w", err)
	}
	defer gz.Close()

	tarReader := tar.NewReader(gz)
	binaryHash := sha256.New()
	foundBinary := false
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("read bundle tar: %w", err)
		}
		cleanName, err := cleanReleaseTarPath(header.Name)
		if err != nil {
			return err
		}
		if cleanName != "bin/darkbloom" {
			continue
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
			return fmt.Errorf("bundled provider binary is not a regular file")
		}
		if foundBinary {
			return fmt.Errorf("bundle contains multiple provider binaries")
		}
		if header.Size < 0 || header.Size > maxReleaseProviderBinBytes {
			return fmt.Errorf("provider binary exceeds maximum size")
		}
		n, err := io.Copy(binaryHash, io.LimitReader(tarReader, maxReleaseProviderBinBytes+1))
		if err != nil {
			return fmt.Errorf("read provider binary: %w", err)
		}
		if n > maxReleaseProviderBinBytes {
			return fmt.Errorf("provider binary exceeds maximum size")
		}
		foundBinary = true
	}
	if !foundBinary {
		return fmt.Errorf("bundle is missing bin/darkbloom")
	}

	actualBinaryHash := hex.EncodeToString(binaryHash.Sum(nil))
	if actualBinaryHash != release.BinaryHash {
		return fmt.Errorf("binary_hash does not match bundled provider binary")
	}
	return nil
}

func cleanReleaseTarPath(name string) (string, error) {
	if name == "" || strings.HasPrefix(name, "/") {
		return "", fmt.Errorf("bundle contains unsafe path")
	}
	for _, part := range strings.Split(name, "/") {
		if part == ".." {
			return "", fmt.Errorf("bundle contains unsafe path")
		}
	}
	return strings.TrimPrefix(path.Clean(name), "./"), nil
}

// handleLatestRelease handles GET /v1/releases/latest.
// Public endpoint — returns the latest active release for a platform.
// Used by install.sh to get the download URL and expected hash.
func (s *Server) handleLatestRelease(w http.ResponseWriter, r *http.Request) {
	platform := r.URL.Query().Get("platform")
	if platform == "" {
		platform = "macos-arm64"
	}

	cacheKey := "latest_release:v1:" + platform
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, http.StatusOK, cached)
		return
	}

	release := s.store.GetLatestRelease(platform)
	if release == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "no active release for platform "+platform))
		return
	}

	body, err := json.Marshal(release)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode release"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, http.StatusOK, body)
}

// handleAdminListReleases handles GET /v1/admin/releases.
// Admin-only — returns all releases (active and inactive).
func (s *Server) handleAdminListReleases(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	releases := s.store.ListReleases()
	if releases == nil {
		releases = []store.Release{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"releases": releases})
}

// handleAdminDeleteRelease handles DELETE /v1/admin/releases.
// Admin-only — deactivates a release version.
func (s *Server) handleAdminDeleteRelease(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Version  string `json:"version"`
		Platform string `json:"platform"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Version == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "version is required"))
		return
	}
	if req.Platform == "" {
		req.Platform = "macos-arm64"
	}

	if err := s.store.DeleteRelease(req.Version, req.Platform); err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
		return
	}

	// Re-sync known hashes after deactivation.
	s.SyncBinaryHashes()
	s.SyncRuntimeManifest()

	s.logger.Info("admin: release deactivated", "version", req.Version, "platform", req.Platform)
	writeJSON(w, http.StatusOK, map[string]any{
		"status":   "release_deactivated",
		"version":  req.Version,
		"platform": req.Platform,
	})
}

// isAdminAuthorized checks if the request is from an admin.
// Accepts either Privy admin (email in admin list) OR EIGENINFERENCE_ADMIN_KEY.
func (s *Server) isAdminAuthorized(w http.ResponseWriter, r *http.Request) bool {
	// Check admin key first (no Privy needed).
	token := extractBearerToken(r)
	if token != "" && s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
		return true
	}

	// Check Privy admin.
	user := auth.UserFromContext(r.Context())
	if user != nil && s.isAdmin(user) {
		return true
	}

	writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
	return false
}

// handleAdminAuthInit handles POST /v1/admin/auth/init.
// Sends an OTP code to the given email via Privy. Used by the admin CLI.
func (s *Server) handleAdminAuthInit(w http.ResponseWriter, r *http.Request) {
	if s.privyAuth == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("not_configured", "Privy auth not configured"))
		return
	}

	var req struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON"))
		return
	}
	if req.Email == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "email is required"))
		return
	}

	if err := s.privyAuth.InitEmailOTP(req.Email); err != nil {
		s.logger.Error("admin auth: OTP init failed", "email", req.Email, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("otp_error", "failed to send OTP: "+err.Error()))
		return
	}

	s.logger.Info("admin auth: OTP sent", "email", req.Email)
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "otp_sent",
		"email":  req.Email,
	})
}

// handleAdminAuthVerify handles POST /v1/admin/auth/verify.
// Verifies the OTP code and returns a Privy access token for admin use.
func (s *Server) handleAdminAuthVerify(w http.ResponseWriter, r *http.Request) {
	if s.privyAuth == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("not_configured", "Privy auth not configured"))
		return
	}

	var req struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON"))
		return
	}
	if req.Email == "" || req.Code == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "email and code are required"))
		return
	}

	token, err := s.privyAuth.VerifyEmailOTP(req.Email, req.Code)
	if err != nil {
		s.logger.Warn("admin auth: OTP verification failed", "email", req.Email, "error", err)
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "OTP verification failed: "+err.Error()))
		return
	}

	s.logger.Info("admin auth: login successful", "email", req.Email)
	writeJSON(w, http.StatusOK, map[string]any{
		"token": token,
		"email": req.Email,
	})
}
