package api

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Unknown-frame instrumentation (zombie-stream amplifier visibility).
//
// A provider that keeps generating into a request the coordinator already
// abandoned (consumer gone, first-chunk timeout, settled) sends chunk /
// complete / error frames whose request_id matches no pending state. The
// coordinator logs each one and (throttled) re-sends a cancel, but during the
// 2026-08-31 cascade ~65K such frames in 10 minutes were invisible on any
// panel: inference.zombie_stream_cancel is throttled and untagged. This
// counter is the raw, unthrottled count, tagged by the FRAME KIND and the
// provider's binary version — bounded vocabularies — so a zombie wave can be
// pinned to a release. It never carries the provider id or the request id.
const (
	metricUnknownFrames        = "inference.unknown_frames"
	metricUnknownFramesCounter = "inference_unknown_frames_total"

	unknownFrameKindChunk    = "chunk"
	unknownFrameKindComplete = "complete"
	unknownFrameKindError    = "error"
)

// maxVersionTagLen bounds the provider_version tag before parsing: a release
// version is short, and anything longer is untrusted input.
const maxVersionTagLen = 32

// versionTagPrereleaseKinds are the prerelease identifiers a release version
// can carry ("0.8.16-rc.1"). Any other prerelease shape is not a release.
var versionTagPrereleaseKinds = map[string]bool{"alpha": true, "beta": true, "rc": true}

// emitUnknownFrame counts one provider frame for an unknown request id.
func (s *Server) emitUnknownFrame(kind string, provider *registry.Provider) {
	if s == nil {
		return
	}
	version := providerVersionTag(provider)
	if s.metrics != nil {
		s.metrics.IncCounter(metricUnknownFramesCounter,
			MetricLabel{"kind", kind}, MetricLabel{"provider_version", version})
	}
	if s.dd == nil {
		return
	}
	s.ddIncr(metricUnknownFrames, []string{"kind:" + kind, "provider_version:" + version})
}

// providerVersionTag reads the provider's reported binary version under its
// lock and fences it to a bounded, tag-safe value.
func providerVersionTag(p *registry.Provider) string {
	if p == nil {
		return "unknown"
	}
	p.Mu().Lock()
	version := p.Version
	p.Mu().Unlock()
	return sanitizeVersionTag(version)
}

// sanitizeVersionTag maps strict semver to a fixed release-family vocabulary.
// Patch versions and arbitrary numeric prereleases cannot mint new series.
// Exact binary versions remain available in provider metadata and logs.
func sanitizeVersionTag(version string) string {
	version = strings.TrimSpace(version)
	if version == "" {
		return "unknown"
	}
	if len(version) > maxVersionTagLen {
		return "other"
	}
	version = strings.TrimPrefix(version, "v")
	core, pre, hasPre := strings.Cut(version, "-")
	segs := strings.Split(core, ".")
	if len(segs) != 3 {
		return "other"
	}
	for _, seg := range segs {
		if !versionTagNumeric(seg) {
			return "other"
		}
	}
	if hasPre {
		kind, n, ok := strings.Cut(pre, ".")
		if !ok || !versionTagPrereleaseKinds[kind] || !versionTagNumeric(n) {
			return "other"
		}
		return "prerelease"
	}
	switch segs[0] + "." + segs[1] {
	case "0.6":
		return "0.6.x"
	case "0.7":
		return "0.7.x"
	case "0.8":
		return "0.8.x"
	case "0.9":
		return "0.9.x"
	default:
		return "other_release"
	}
}

// versionTagNumeric reports whether s is a semver numeric identifier: one or
// more ASCII digits with no leading zero (or exactly "0").
func versionTagNumeric(s string) bool {
	if s == "" || (len(s) > 1 && s[0] == '0') {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
