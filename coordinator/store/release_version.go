package store

import (
	"strings"

	"golang.org/x/mod/semver"
)

const (
	ReleaseChannelStable = "stable"
	ReleaseChannelBeta   = "beta"
)

func normalizeReleaseChannel(channel string) (string, bool) {
	switch strings.ToLower(strings.TrimSpace(channel)) {
	case "", ReleaseChannelStable:
		return ReleaseChannelStable, true
	case ReleaseChannelBeta:
		return ReleaseChannelBeta, true
	default:
		return "", false
	}
}

func releaseVisibleToChannel(releaseChannel, requestedChannel string) bool {
	releaseChannel, releaseOK := normalizeReleaseChannel(releaseChannel)
	requestedChannel, requestedOK := normalizeReleaseChannel(requestedChannel)
	if !releaseOK || !requestedOK {
		return false
	}
	return releaseChannel == ReleaseChannelStable || requestedChannel == ReleaseChannelBeta
}

func validReleaseVersion(version string) bool {
	return semver.IsValid("v" + strings.TrimPrefix(strings.TrimSpace(version), "v"))
}

func releaseVersionGreater(a, b string) bool {
	if a == "" {
		return false
	}
	if b == "" {
		return true
	}
	return semver.Compare("v"+strings.TrimPrefix(a, "v"), "v"+strings.TrimPrefix(b, "v")) > 0
}
