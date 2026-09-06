package testbed

// Readiness refusals remain evidence even when a later observation is ready.
type ProviderEntryCheck struct {
	Observation HostObservation `json:"observation"`
	Ready       bool            `json:"ready"`
	Reason      *string         `json:"reason"`
}

// These identities distinguish the local helper transport, host fixture, and
// actual provider. A fixture process alone never establishes provider startup.
type ProviderHostLifecycle struct {
	Name               string               `json:"name"`
	Root               string               `json:"root"`
	HelperTransportPID int                  `json:"helper_transport_pid"`
	FixturePID         int                  `json:"fixture_pid"`
	ProviderStarted    bool                 `json:"provider_started"`
	ProviderPID        int                  `json:"provider_pid"`
	EntryChecks        []ProviderEntryCheck `json:"entry_checks"`
	Terminal           *ownedHostEvent      `json:"terminal,omitempty"`
	Cleanup            *HostObservation     `json:"cleanup,omitempty"`
}

func (p *Provider) HostLifecycle() ProviderHostLifecycle {
	row := ProviderHostLifecycle{}
	if p.Target != nil {
		row.Name, row.Root = p.Target.Name, p.Target.Root
	}
	if p.owned == nil {
		return row
	}
	o := p.owned
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.cmd.Process != nil {
		row.HelperTransportPID = o.cmd.Process.Pid
	}
	row.FixturePID, row.ProviderPID, row.ProviderStarted = o.fixturePID, o.pid, o.pid > 0
	row.EntryChecks = append([]ProviderEntryCheck(nil), o.entryChecks...)
	if o.terminal != nil {
		copied := *o.terminal
		row.Terminal = &copied
	}
	if o.cleanup != nil {
		copied := *o.cleanup
		row.Cleanup = &copied
	}
	return row
}

// Includes failed and never-attempted targets; successful host registration is
// separately required by HostBindings and the correctness comparator.
func (s *Suite) HostLifecycles() []ProviderHostLifecycle {
	if s.Config.ProviderTargets == nil {
		return nil
	}
	out := make([]ProviderHostLifecycle, len(s.Config.ProviderTargets))
	for i, target := range s.Config.ProviderTargets {
		out[i] = ProviderHostLifecycle{Name: target.Name, Root: target.Root}
	}
	for _, p := range s.providerAttempts {
		if p.ProviderIndex >= 0 && p.ProviderIndex < len(out) {
			out[p.ProviderIndex] = p.HostLifecycle()
		}
	}
	return out
}
