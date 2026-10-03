package observation

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"strings"
)

func SanitizeChipFamilyTag(family string) string {
	family = strings.TrimSpace(family)
	switch family {
	case "", "Unknown":
		return "unknown"
	case "M1", "M1 Pro", "M1 Max", "M1 Ultra",
		"M2", "M2 Pro", "M2 Max", "M2 Ultra",
		"M3", "M3 Pro", "M3 Max", "M3 Ultra",
		"M4", "M4 Pro", "M4 Max", "M4 Ultra",
		"M5", "M5 Pro", "M5 Max", "M5 Ultra", "M6":
		return strings.ReplaceAll(family, " ", "_")
	default:
		return "other"
	}
}

func ProviderChipFamily(p *registry.Provider) string {
	if p == nil {
		return ""
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.Hardware.ChipFamily
}

// maxVersionTagLen bounds the provider_version tag before parsing: a release
// version is short, and anything longer is untrusted input.
const maxVersionTagLen = 32

// versionTagPrereleaseKinds are the prerelease identifiers a release version
// can carry ("0.8.16-rc.1"). Any other prerelease shape is not a release.
var versionTagPrereleaseKinds = map[string]bool{"alpha": true, "beta": true, "rc": true}

// ProviderVersionTag reads the provider's reported binary version under its
// lock and fences it to a bounded, tag-safe value.
func ProviderVersionTag(p *registry.Provider) string {
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
func BoolGauge(value bool) float64 {
	if value {
		return 1
	}
	return 0
}
