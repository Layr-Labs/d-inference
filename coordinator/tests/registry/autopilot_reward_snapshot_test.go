package registry_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func rewardConsentState() *protocol.ModelAutopilotState {
	consent := true
	return &protocol.ModelAutopilotState{
		Protocol: protocol.ModelAutopilotProtocol, ConsentEnabled: &consent,
		CachedOnly: true, Revision: "saved-selection", SelectedModels: []string{"cached-model"},
	}
}

func TestAutopilotRewardConsentUsesSavedSettingsNotControlReadiness(t *testing.T) {
	tests := []struct {
		name          string
		change        func(*protocol.ModelAutopilotState)
		want          bool
		wantSupported bool
	}{
		{"inventory_refresh", func(s *protocol.ModelAutopilotState) { s.Enabled = false }, true, true},
		{"paused", func(s *protocol.ModelAutopilotState) { s.Paused = true }, true, true},
		{"shadow", func(s *protocol.ModelAutopilotState) { s.ObserveOnly = true }, true, true},
		{"no_control_lease", func(s *protocol.ModelAutopilotState) { s.Active, s.SessionID = false, "" }, true, true},
		{"old_wire_enabled", func(s *protocol.ModelAutopilotState) { s.Enabled, s.ConsentEnabled = true, nil }, false, false},
		{"saved_opt_out", func(s *protocol.ModelAutopilotState) { *s.ConsentEnabled = false; s.Enabled = true }, false, true},
		{"empty_opt_out", func(s *protocol.ModelAutopilotState) {
			*s.ConsentEnabled = false
			s.Revision, s.SelectedModels = "", nil
		}, false, true},
		{"unsupported_protocol", func(s *protocol.ModelAutopilotState) { s.Protocol++ }, false, false},
		{"noncached", func(s *protocol.ModelAutopilotState) { s.CachedOnly = false }, false, false},
		{"missing_revision", func(s *protocol.ModelAutopilotState) { s.Revision = "" }, false, false},
		{"oversized_revision", func(s *protocol.ModelAutopilotState) { s.Revision = strings.Repeat("r", 65) }, false, false},
		{"empty_selection", func(s *protocol.ModelAutopilotState) { s.SelectedModels = nil }, false, false},
		{"malformed_selection", func(s *protocol.ModelAutopilotState) { s.SelectedModels = []string{""} }, false, false},
		{"oversized_selection", func(s *protocol.ModelAutopilotState) { s.SelectedModels = make([]string, 257) }, false, false},
		{"malformed_snapshot", func(s *protocol.ModelAutopilotState) { s.SessionID = strings.Repeat("s", 129) }, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := registry.New(testLogger())
			state := rewardConsentState()
			tt.change(state)
			p := r.Register("provider", nil, &protocol.RegisterMessage{ModelAutopilot: state})
			if got, supported := p.AutopilotRewardConsentSnapshot(); got != tt.want || supported != tt.wantSupported {
				t.Fatalf("reward consent = %v, supported = %v, want %v/%v", got, supported, tt.want, tt.wantSupported)
			}
			if p.ModelAutopilot.Enabled != state.Enabled {
				t.Fatal("reward consent changed scheduler readiness")
			}
		})
	}

	r := registry.New(testLogger())
	p := r.Register("no-snapshot", nil, &protocol.RegisterMessage{})
	if optedIn, supported := p.AutopilotRewardConsentSnapshot(); optedIn || supported {
		t.Fatal("absent snapshot enrolled a provider")
	}
	state := rewardConsentState()
	if autopilotstate.Consented(state) {
		t.Fatal("saved consent granted control during inventory refresh")
	}
	state.Enabled, *state.ConsentEnabled = true, false
	if !autopilotstate.Consented(state) {
		t.Fatal("saved consent wire changed the existing scheduling gate")
	}
}

func TestAutopilotRewardConsentUsesAcceptedHeartbeatAndDetachedState(t *testing.T) {
	r := registry.New(testLogger())
	state := rewardConsentState()
	p := r.Register("provider", nil, &protocol.RegisterMessage{ModelAutopilot: state})
	*state.ConsentEnabled = false
	if optedIn, supported := p.AutopilotRewardConsentSnapshot(); !optedIn || !supported {
		t.Fatal("registration retained the caller's consent pointer")
	}
	state = rewardConsentState()
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{ModelAutopilot: state, BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 2}}) {
		t.Fatal("fresh heartbeat rejected")
	}
	*state.ConsentEnabled = false
	if optedIn, supported := p.AutopilotRewardConsentSnapshot(); !optedIn || !supported {
		t.Fatal("heartbeat retained the caller's consent pointer")
	}
	if r.Heartbeat(p.ID, &protocol.HeartbeatMessage{ModelAutopilot: state, BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1}}) {
		t.Fatal("stale heartbeat accepted")
	}
	if optedIn, supported := p.AutopilotRewardConsentSnapshot(); !optedIn || !supported {
		t.Fatal("stale capacity heartbeat overwrote accepted saved consent")
	}
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 3}}) {
		t.Fatal("fresh missing-consent heartbeat rejected")
	}
	if optedIn, supported := p.AutopilotRewardConsentSnapshot(); optedIn || supported {
		t.Fatal("omitted current declaration retained prior reward consent")
	}
}

func TestAutopilotRewardConsentClonePointerIsolation(t *testing.T) {
	for _, consent := range []bool{false, true} {
		state := &protocol.ModelAutopilotState{ConsentEnabled: &consent}
		first, second := autopilot.CloneState(state), autopilot.CloneState(state)
		if first.ConsentEnabled == state.ConsentEnabled || first.ConsentEnabled == second.ConsentEnabled {
			t.Fatal("clones share the mutable saved-consent pointer")
		}
		*first.ConsentEnabled = !consent
		if *state.ConsentEnabled != consent || *second.ConsentEnabled != consent {
			t.Fatal("mutating one snapshot changed another snapshot's consent")
		}
	}
	if autopilot.CloneState(&protocol.ModelAutopilotState{}).ConsentEnabled != nil {
		t.Fatal("clone invented consent for a legacy snapshot")
	}
}
