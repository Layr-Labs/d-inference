package releases

const (
	VersionCacheKey         = "api_version:v1"
	runtimeManifestCacheKey = "runtime_manifest:v1"
	DefaultPlatform         = "macos-arm64"
)

func latestReleaseCacheKey(platform string) string {
	return "latest_release:v1:" + platform
}

// invalidateReleaseCaches is the single release-mutation cache boundary.
// Runtime policy can include every active platform, while /api/version is the
// macOS provider discovery surface. The latest-release response is always
// platform-scoped.
func (s *Controller) invalidateReleaseCaches(platform string) {
	s.cache().Invalidate(latestReleaseCacheKey(platform))
	s.cache().Invalidate(runtimeManifestCacheKey)
	if platform == DefaultPlatform {
		s.cache().Invalidate(VersionCacheKey)
	}
}
