package releases

import (
	"fmt"
	"net"
	"net/url"
	"path"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Controller) trustedReleaseArtifactURL(release *store.Release) (*url.URL, error) {
	expectedURL, err := expectedReleaseArtifactURL(s.cdnURL(), release.Version, release.Platform)
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
	u.Path = path.Join(u.Path, "releases", "v"+version, "darkbloom-bundle-"+platform+".tar.gz")
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
