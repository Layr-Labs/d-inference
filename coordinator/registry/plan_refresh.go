package registry

// RefreshDispatchPlan performs the plan's single full re-scan refresh: a fresh
// ReserveProviderWithPlan excluding every provider the exhausted plan already
// attempted (winner + every visited entry) plus the caller's exclusions. The
// returned plan is born with its refresh consumed, so a request chain gets at
// most one re-scan no matter how plans are threaded. Returns performed=false
// (and scans nothing) when the refresh was already used or plan is nil; a
// performed refresh that finds no provider returns a nil provider and nil
// plan with the failure RoutingDecision, exactly like ReserveProviderWithPlan.
func (r *Registry) RefreshDispatchPlan(pr *PendingRequest, plan *DispatchPlan, excludeIDs ...string) (p *Provider, decision RoutingDecision, fresh *DispatchPlan, performed bool) {
	if plan == nil {
		return nil, RoutingDecision{}, nil, false
	}
	exclude, claimed := plan.state.ClaimRefresh(len(excludeIDs))
	if !claimed {
		return nil, RoutingDecision{Model: plan.Model()}, nil, false
	}
	exclude = append(exclude, excludeIDs...)

	p, decision, fresh = r.reserveProvider(plan.Model(), pr, true, exclude...)
	if fresh != nil {
		fresh.state.MarkRefreshed()
	}
	return p, decision, fresh, true
}
