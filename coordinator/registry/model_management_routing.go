package registry

import "time"

// providerAutopilotRoutingBlockedLocked is a capacity gate, not a catalog or
// trust gate. Managed providers retain their cached inventory for planning but
// accept network inference only on confirmed warm models, outside transitions.
// The provider applies the same rule, including owner requests over the network;
// direct local inference retains its independent admission/ownership checks.
// Caller holds r.mu and p.mu.
func providerAutopilotRoutingBlockedLocked(p *Provider, model string) bool {
	return p.autopilotState.RoutingBlocked(p.ModelAutopilot, p.ID, model, p.BackendCapacity, time.Now)
}

// Active control or an explicit pause owns residency. Accepted commands retain
// their fence until reconciliation. Consent without control keeps ordinary
// serving policy, and a hypothetical plan never claims mutation ownership.
func providerLegacyModelChangesBlockedLocked(p *Provider) bool {
	return p.autopilotState.LegacyChangesBlocked(p.ModelAutopilot, p.ID, time.Now)
}
