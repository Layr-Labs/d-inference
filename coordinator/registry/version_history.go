package registry

import "time"

// Version history shares the existing identity gate and its periodic sweep.
// Retain departed versions beyond the disconnect-cache and reset windows;
// live sessions and active faults also keep their gate through pruneLocked.
const identityVersionRetention = 20 * time.Minute

// Caller holds gate.mu. touched records both outcome activity and disconnect,
// so even a long-lived idle session receives a full reconnect grace window.
func (g *gateState) versionHistoryActive(now time.Time) bool {
	return g.identityVersion != "" && (now.Sub(g.touched) <= identityVersionRetention ||
		(!g.versionResetAt.IsZero() && now.Sub(g.versionResetAt) <= identityVersionRetention))
}
