package testbed

import "fmt"

// Readiness refusals remain evidence even when a later observation is ready.
type ProviderEntryCheck struct {
	Observation HostObservation `json:"observation"`
	Ready       bool            `json:"ready"`
	Reason      *string         `json:"reason"`
}

// These identities distinguish the local helper transport, host fixture, and
// actual provider. A fixture process alone never establishes provider startup.
type ProviderHostLifecycle struct {
	Name                 string               `json:"name"`
	Root                 string               `json:"root"`
	HelperTransportPID   int                  `json:"helper_transport_pid"`
	FixturePID           int                  `json:"fixture_pid"`
	ProviderStarted      *bool                `json:"provider_started"`
	StartAcknowledged    bool                 `json:"start_acknowledged"`
	StartupIdentityError string               `json:"startup_identity_error,omitempty"`
	ControlError         string               `json:"control_error,omitempty"`
	ProviderPID          int                  `json:"provider_pid"`
	EntryChecks          []ProviderEntryCheck `json:"entry_checks"`
	Terminal             *ownedHostEvent      `json:"terminal,omitempty"`
	Cleanup              *HostObservation     `json:"cleanup,omitempty"`
}

func (p *Provider) HostLifecycle() ProviderHostLifecycle {
	row := ProviderHostLifecycle{ProviderStarted: startupBool(false)}
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
	row.FixturePID, row.StartAcknowledged = o.fixturePID, o.pid > 0
	var identityErr error
	row.ProviderStarted, row.ProviderPID, identityErr = providerStartupIdentity(o.pid, o.terminal)
	if identityErr != nil {
		row.StartupIdentityError = identityErr.Error()
	}
	if o.err != nil {
		row.ControlError = o.err.Error()
	}
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
		out[i] = ProviderHostLifecycle{Name: target.Name, Root: target.Root, ProviderStarted: startupBool(false)}
	}
	for _, p := range s.providerAttempts {
		if p.ProviderIndex >= 0 && p.ProviderIndex < len(out) {
			out[p.ProviderIndex] = p.HostLifecycle()
		}
	}
	return out
}

func startupBool(value bool) *bool { return &value }

// A terminal can prove Popen succeeded even if the start acknowledgement was
// lost. It never grants startup acknowledgement or authorizes registration.
// nil means unknown, rather than inferring "not started" from a missing frame.
func providerStartupIdentity(acknowledgedPID int, terminal *ownedHostEvent) (*bool, int, error) {
	var known *bool
	pid := acknowledgedPID
	if pid > 0 {
		known = startupBool(true)
	}
	if terminal == nil {
		return known, pid, nil
	}
	invalid := func(reason string) (*bool, int, error) {
		return known, pid, fmt.Errorf("contradictory provider startup identity: %s", reason)
	}
	if terminal.ProviderStarted == nil {
		// Older injected CPU fixtures omit the flag. They cannot prove an
		// unacknowledged launch or an unstarted provider.
		if acknowledgedPID <= 0 {
			return invalid("terminal startup flag absent without acknowledgement")
		}
		if terminal.PID != acknowledgedPID || (terminal.PGID != 0 && terminal.PGID != acknowledgedPID) {
			return invalid("legacy terminal PID/group differs from acknowledgement")
		}
		return known, pid, nil
	}
	if *terminal.ProviderStarted {
		if terminal.PID <= 0 || terminal.PGID != terminal.PID {
			return invalid("started terminal requires positive matching PID/group")
		}
		if acknowledgedPID > 0 && acknowledgedPID != terminal.PID {
			return invalid("terminal PID differs from acknowledgement")
		}
		return startupBool(true), terminal.PID, nil
	}
	if acknowledgedPID != 0 || terminal.PID != 0 || terminal.PGID != 0 || terminal.ExitCode != nil {
		return invalid("unstarted terminal conflicts with process identity")
	}
	return startupBool(false), 0, nil
}
