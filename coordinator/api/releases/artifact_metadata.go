package releases

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"net/url"
	"path"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) validateReleaseMetadata(release *store.Release) error {
	release.Version = strings.TrimSpace(release.Version)
	release.Platform = strings.TrimSpace(release.Platform)
	release.Backend = strings.TrimSpace(release.Backend)
	release.BinaryHash = strings.TrimSpace(release.BinaryHash)
	release.BundleHash = strings.TrimSpace(release.BundleHash)
	release.MetallibHash = strings.TrimSpace(release.MetallibHash)
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
	if release.BinaryHash, err = NormalizeSHA256Hex(release.BinaryHash, "binary_hash"); err != nil {
		return err
	}
	if release.BundleHash, err = NormalizeSHA256Hex(release.BundleHash, "bundle_hash"); err != nil {
		return err
	}
	if release.MetallibHash != "" {
		if release.MetallibHash, err = NormalizeSHA256Hex(release.MetallibHash, "metallib_hash"); err != nil {
			return err
		}
	}
	if release.Backend == "mlx-swift" && release.MetallibHash == "" {
		return fmt.Errorf("metallib_hash is required for mlx-swift releases")
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

func (s *Owner) trustedReleaseArtifactURL(release *store.Release) (*url.URL, error) {
	expectedURL, err := expectedReleaseArtifactURL(s.r2CDNURL, release.Version, release.Platform)
	if err != nil {
		return nil, err
	}
	if !sameReleaseArtifactURL(release.URL, expectedURL) {
		immutable, err := expectedReleaseArtifactURL(s.r2CDNURL, release.Version, release.Platform, release.BundleHash)
		if err != nil || !sameReleaseArtifactURL(release.URL, immutable) {
			return nil, fmt.Errorf("url must match configured release artifact path")
		}
		expectedURL = immutable
	}
	parsed, err := url.Parse(expectedURL)
	if err != nil {
		return nil, fmt.Errorf("configured release artifact URL is invalid")
	}
	return parsed, nil
}

func expectedReleaseArtifactURL(baseURL, version, platform string, bundleHash ...string) (string, error) {
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
	u.Path = path.Join(u.Path, "releases", "v"+version)
	if len(bundleHash) > 0 {
		hash, err := NormalizeSHA256Hex(bundleHash[0], "bundle_hash")
		if err != nil {
			return "", err
		}
		u.Path = path.Join(u.Path, "artifacts", hash)
	}
	u.Path = path.Join(u.Path, "darkbloom-bundle-"+platform+".tar.gz")
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

func NormalizeSHA256Hex(value, field string) (string, error) {
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
		hash, err := NormalizeSHA256Hex(hash, "template_hashes")
		if err != nil {
			return "", err
		}
		normalized = append(normalized, name+"="+hash)
	}
	return strings.Join(normalized, ","), nil
}
