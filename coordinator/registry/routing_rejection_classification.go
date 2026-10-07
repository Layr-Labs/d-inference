package registry

import "time"

// classifyRejectedProvider identifies the rejection states that control the
// fail-open rescan and the capacity/no-provider response. These are routing
// decisions, so a view loaded before a shared-identity rebind must be confirmed
// before its now-empty source gate can suppress either classification.
// Caller holds r.mu and no p.mu; p.mu stays held through the reads and their
// confirmation, preventing another rebind from invalidating the new view.
func (r *Registry) classifyRejectedProvider(view gateView, model string, traits RequestTraits, selfRouteOwner, ignoreProviderBreaker bool, now time.Time) (breaker, capacity bool) {
	p := view.p
	p.mu.Lock()
	defer p.mu.Unlock()
	return view.g.view.ClassifyRejection(model, now, ignoreProviderBreaker,
		func() string { return stableProviderIdentityLocked(p) },
		func() bool { return providerDrainingLocked(p, now) },
		func() bool {
			return r.providerPassesRoutingGatesLockedEx(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, true)
		})
}
