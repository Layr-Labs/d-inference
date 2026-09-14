package api

import "github.com/eigeninference/d-inference/coordinator/api/releases"

// The version endpoint and release controller share the same cache key and
// installer platform. Release mutation invalidation is owned by the controller.
const (
	apiVersionCacheKey     = releases.VersionCacheKey
	defaultReleasePlatform = releases.DefaultPlatform
)
