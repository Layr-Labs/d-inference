package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// tallyCounts updates the fleet aggregate based on one machine's merged state.
func tallyCounts(c *myFleetCounts, mp *myProvider, minVersion string) {
	c.Total++
	switch mp.Status {
	case "serving":
		c.Serving++
	case string(registry.StatusOnline):
		c.Online++
	case string(registry.StatusUntrusted):
		c.Untrusted++
	default: // offline, never_seen
		c.Offline++
	}
	if mp.TrustLevel == string(registry.TrustHardware) {
		c.Hardware++
	}
	if needsAttention(mp, minVersion) {
		c.NeedsAttn++
	}
}

// needsAttention is the server-side mirror of the client warning logic. It's
// only used for the summary count, not for individual warning text. The UI
// renders detailed warnings from the per-machine payload.
func needsAttention(mp *myProvider, minVersion string) bool {
	if mp.Status == string(registry.StatusUntrusted) {
		return true
	}
	if mp.Status == "offline" || mp.Status == "never_seen" {
		return true
	}
	if !mp.RuntimeVerified {
		return true
	}
	if mp.TrustLevel != string(registry.TrustHardware) {
		return true
	}
	if mp.FailedChallenges > 0 {
		return true
	}
	if minVersion != "" && mp.Version != "" && semverLess(mp.Version, minVersion) {
		return true
	}
	return false
}
