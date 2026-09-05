package registry

import "time"

// ServiceStatus is an observation of public routing eligibility, not a
// reservation or a claim that this provider is earning. The request shape is
// explicit because eligibility differs across models, tools and prompt sizes.
type ServiceStatus struct {
	SchemaVersion   int                  `json:"schema_version"`
	ObservedAt      time.Time            `json:"observed_at"`
	ExpiresAt       time.Time            `json:"expires_at"`
	State           string               `json:"state"`
	Reason          string               `json:"reason,omitempty"`
	PendingRequests int                  `json:"pending_requests"`
	Probe           ServiceStatusProbe   `json:"probe"`
	Models          []ModelServiceStatus `json:"models"`
}

type ServiceStatusProbe struct {
	Scope        string `json:"scope"`
	PromptTokens int    `json:"prompt_tokens"`
	MaxTokens    int    `json:"max_tokens"`
}

type ModelServiceStatus struct {
	Model          string  `json:"model"`
	Eligible       bool    `json:"eligible"`
	Reason         string  `json:"reason"`
	CapacityRateMs float64 `json:"capacity_rate_ms"`
}

// ProviderServiceStatus uses the same snapshot and cost builder as dispatch.
// It evaluates one account-owned provider at a time, without reserving work,
// claiming recovery probes, clearing breakers, or performing any store I/O.
// Account ownership is rechecked under the lock: a stale fleet merge must not
// attach another account's current operational state.
func (r *Registry) ProviderServiceStatus(accountID, providerID string, now time.Time) *ServiceStatus {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p := r.providers[providerID]
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.AccountID != accountID {
		return nil
	}
	out := &ServiceStatus{
		SchemaVersion: 1,
		ObservedAt:    now, ExpiresAt: now.Add(30 * time.Second),
		State: "unavailable", PendingRequests: p.pendingCount(),
		Probe:  ServiceStatusProbe{Scope: "public_text", PromptTokens: fleetSampleProbePromptTokens, MaxTokens: fleetSampleProbeMaxTokens},
		Models: make([]ModelServiceStatus, 0, len(p.Models)),
	}
	if p.Status == StatusOffline {
		out.State, out.Reason = "offline", "offline"
		return out
	}
	// The API already advertises a 90-second heartbeat freshness limit. Do
	// not present a stale capacity report as fresh just because it was read now.
	heartbeatExpiry := p.LastHeartbeat.Add(90 * time.Second)
	if p.LastHeartbeat.IsZero() || !now.Before(heartbeatExpiry) {
		out.State, out.Reason = "unknown", "heartbeat_stale"
		return out
	}
	if heartbeatExpiry.Before(out.ExpiresAt) {
		out.ExpiresAt = heartbeatExpiry
	}
	if providerDrainingLocked(p, now) {
		out.State, out.Reason = "draining", "draining"
		return out
	}
	pr := &PendingRequest{EstimatedPromptTokens: out.Probe.PromptTokens, RequestedMaxTokens: out.Probe.MaxTokens}
	eligible := 0
	penalized := false
	allBusy := true
	for _, model := range p.Models {
		var candidate routingCandidate
		ok, reason := r.snapshotProviderIntoPLockedEx(&candidate.snapshot, p, model.ID, pr.Traits, false, false, now)
		if ok {
			_, reason, ok = r.buildCandidateInto(&candidate, pr, now)
		}
		row := ModelServiceStatus{Model: model.ID, Eligible: ok, Reason: reason.String()}
		if ok {
			eligible++
			row.Reason = EligibilityReasonEligible
			row.CapacityRateMs = candidate.breakdown.CapacityRateMs
			penalized = penalized || row.CapacityRateMs > 0
		} else {
			allBusy = allBusy && (reason == GateNoHeadroom || reason == GateFreeMemory)
			if out.Reason == "" {
				out.Reason = row.Reason
			}
		}
		out.Models = append(out.Models, row)
	}
	switch {
	case len(out.Models) == 0:
		out.Reason = "no_models"
	case eligible == len(out.Models) && !penalized:
		out.State, out.Reason = "ready", ""
	case eligible == 0 && allBusy:
		out.State = "busy"
	case eligible > 0:
		out.State = "limited"
		if out.Reason == "" {
			out.Reason = "capacity_rate"
		}
	}
	return out
}
