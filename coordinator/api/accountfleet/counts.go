package accountfleet

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// fleetCounts aggregates machine counts by status for the dashboard header.
type fleetCounts struct {
	Total     int `json:"total"`
	Online    int `json:"online"`          // status==online
	Serving   int `json:"serving"`         // status==serving
	Offline   int `json:"offline"`         // status==offline OR never_seen
	Untrusted int `json:"untrusted"`       // status==untrusted
	Hardware  int `json:"hardware"`        // trust_level==hardware
	NeedsAttn int `json:"needs_attention"` // any of: !runtime_verified, trust!=hardware, untrusted, version below min
}

// tallyCounts updates the fleet aggregate based on one machine's merged state.
func (s *Controller) tallyCounts(c *fleetCounts, mp *providerView, minVersion string) {
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
	if s.needsAttention(mp, minVersion) {
		c.NeedsAttn++
	}
}

// needsAttention is the server-side mirror of the client warning logic. It's
// only used for the summary count, not for individual warning text. The UI
// renders detailed warnings from the per-machine payload.
func (s *Controller) needsAttention(mp *providerView, minVersion string) bool {
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
	if minVersion != "" && mp.Version != "" && s.versionLess(mp.Version, minVersion) {
		return true
	}
	return false
}
