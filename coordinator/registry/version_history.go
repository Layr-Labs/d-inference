package registry

import "time"

// Keep departed identities beyond both the disconnect-cache TTL and the reset
// throttle/fault windows. Live identities and active quarantines are retained.
const identityVersionRetention = 20 * time.Minute
const identityVersionSweepInterval = time.Minute

func (r *Registry) touchIdentityVersionLocked(stableID string, now time.Time) {
	if _, exists := r.identityVersions[stableID]; !exists {
		return
	}
	if r.identityVersionSeenAt == nil {
		r.identityVersionSeenAt = make(map[string]time.Time)
	}
	r.identityVersionSeenAt[stableID] = now
}

// sweepIdentityVersionHistory also runs from the eviction loop, so departed
// identities expire even when new registrations stop. Registration runs the
// same sweep opportunistically; both paths share the rate limit under r.mu.
func (r *Registry) sweepIdentityVersionHistory(now time.Time) {
	r.mu.RLock()
	due := len(r.identityVersions) > 0 && now.Sub(r.identityVersionSweepAt) >= identityVersionSweepInterval
	r.mu.RUnlock()
	if !due {
		return
	}
	hold := r.lockWrite("version_history")
	defer hold.unlock()
	r.pruneIdentityVersionsLocked(now)
}

func (r *Registry) pruneIdentityVersionsLocked(now time.Time) {
	if now.Sub(r.identityVersionSweepAt) < identityVersionSweepInterval {
		return
	}
	r.identityVersionSweepAt = now
	retained := make(map[string]bool, len(r.faultKeyBySession))
	for _, stableID := range r.faultKeyBySession {
		retained[stableID] = true
	}
	for key, until := range r.inferenceErrorCooldowns {
		if now.Before(until) {
			retained[key.ProviderID] = true
		}
	}
	for stableID, until := range r.providerBreakerOpenUntil {
		if now.Before(until) {
			retained[stableID] = true
		}
	}
	for stableID, until := range r.healthEjectionUntil {
		if now.Before(until) {
			retained[stableID] = true
		}
	}
	for key, strikes := range r.inferenceErrorStrikes {
		if len(strikes) > 0 && now.Sub(strikes[len(strikes)-1]) < inferenceErrorWindow {
			retained[key.ProviderID] = true
		}
	}
	for stableID, window := range r.providerOutcomes {
		if total, _ := window.windowStats(now, providerBreakerWindow); total > 0 {
			retained[stableID] = true
		}
	}
	for stableID, window := range r.healthEjectionWindows {
		if total, _ := window.windowStats(now, healthEjectionWindow); total > 0 {
			retained[stableID] = true
		}
	}
	for stableID, streak := range r.healthEjectionCapacityStreaks {
		if streak.n > 0 && now.Sub(streak.last) < healthEjectionWindow {
			retained[stableID] = true
		}
	}
	cutoff := now.Add(-identityVersionRetention)
	for stableID := range r.identityVersions {
		seen, known := r.identityVersionSeenAt[stableID]
		if !known {
			// Bare test registries or pre-populated history get one full grace
			// window rather than being discarded at their first sweep.
			r.touchIdentityVersionLocked(stableID, now)
			continue
		}
		if retained[stableID] || !seen.Before(cutoff) || !r.identityVersionResetAt[stableID].Before(cutoff) {
			continue
		}
		delete(r.identityVersions, stableID)
		delete(r.identityVersionResetAt, stableID)
		delete(r.identityVersionSeenAt, stableID)
	}
}
