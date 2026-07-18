package api

const (
	apiVersionCacheKey      = "api_version:v1"
	runtimeManifestCacheKey = "runtime_manifest:v1"
	defaultReleasePlatform  = "macos-arm64"
)

func latestReleaseCacheKey(platform string) string {
	return "latest_release:v1:" + platform
}

// invalidateReleaseCaches is the single release-mutation cache boundary.
// Runtime policy can include every active platform, while /api/version is the
// macOS provider discovery surface. The latest-release response is always
// platform-scoped.
func (s *Server) invalidateReleaseCaches(platform string) {
	s.readCache.Invalidate(latestReleaseCacheKey(platform))
	s.readCache.Invalidate(runtimeManifestCacheKey)
	if platform == defaultReleasePlatform {
		s.readCache.Invalidate(apiVersionCacheKey)
	}
}
