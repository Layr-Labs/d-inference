package registry_test

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"

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

func qualifiedAutopilotRewardProvider(t *testing.T, cachedOnly bool) (*registry.Registry, *registry.Provider, registry.AppAttestServingAuthorization) {
	t.Helper()
	r := registry.New(testLogger())
	r.SetAppAttestServingPolicy(true, 7)
	state := rewardConsentState()
	state.Enabled = true
	state.SelectedModels = []string{appAttestTestModel, "second-model"}
	models := []protocol.ModelInfo{
		{ID: appAttestTestModel, WeightHash: strings.Repeat("a", 64)},
		{ID: "second-model", WeightHash: strings.Repeat("b", 64)},
	}
	msg := testRegisterMessage()
	msg.ModelAutopilot = state
	msg.Models = models
	if cachedOnly {
		msg.Models, msg.AutopilotInventory = nil, models
	}
	p := makeSchedulerProviderWithRegistration(t, r, "reward-provider", appAttestTestModel, msg)
	p.Mu().Lock()
	p.AccountID = "account-1"
	p.BackendCapacity, p.CurrentModel, p.WarmModels = nil, "", nil
	p.Mu().Unlock()
	if !r.BindVerifiedMachineIdentity(p, "account-1", "machine-1") {
		t.Fatal("bind identity")
	}
	r.SetModelCatalog([]registry.CatalogEntry{
		{ID: appAttestTestModel, WeightHash: strings.Repeat("a", 64), MinRAMGB: 16},
		{ID: "second-model", WeightHash: strings.Repeat("b", 64), MinRAMGB: 16},
	})
	now := time.Now()
	lease := registry.AppAttestServingAuthorization{
		AccountID: p.AccountID, MachineID: "machine-1", CredentialID: "credential-1",
		ConnectionID: p.ID, ProofSessionID: "proof-session", Endpoint: p.PublicKey,
		PolicyGeneration: 7, IssuedAt: now, ValidUntil: now.Add(time.Minute),
		MachineModel: p.Hardware.MachineModel, MemoryGB: p.Hardware.MemoryGB, OSVersion: "27.0.1",
	}
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant current App Attest authorization")
	}
	return r, p, lease
}

func TestAutopilotRewardQualificationRequiresTrustedOSAndEligibleDownloadedSelection(t *testing.T) {
	tests := []struct {
		name   string
		change func(*registry.Registry, *registry.Provider, registry.AppAttestServingAuthorization)
	}{
		{"inventory_refresh", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.ModelAutopilot.Enabled = false
		}},
		{"one_downloaded", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.Models = p.Models[:1]
		}},
		{"one_selected", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.ModelAutopilot.SelectedModels = p.ModelAutopilot.SelectedModels[:1]
		}},
		{"duplicate_selection", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.ModelAutopilot.SelectedModels = []string{appAttestTestModel, appAttestTestModel}
		}},
		{"duplicate_inventory", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.Models = append(p.Models, p.Models[0])
		}},
		{"off_catalog", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.Models[1].ID, p.ModelAutopilot.SelectedModels[1] = "local-model", "local-model"
		}},
		{"missing_weight_hash", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.Models[1].WeightHash = ""
		}},
		{"wrong_artifact", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.Models[1].WeightHash = strings.Repeat("f", 64)
		}},
		{"broken_template", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.Models[1].TemplateRenderOK = boolPtr(false)
		}},
		{"runtime_unverified", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.RuntimeVerified = false
		}},
		{"private", func(_ *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			p.PrivateOnly = true
		}},
		{"no_catalog_policy", func(r *registry.Registry, _ *registry.Provider, _ registry.AppAttestServingAuthorization) {
			r.SetModelCatalog(nil)
		}},
		{"catalog_deleted", func(r *registry.Registry, _ *registry.Provider, _ registry.AppAttestServingAuthorization) {
			r.SetModelCatalog([]registry.CatalogEntry{{ID: appAttestTestModel, WeightHash: strings.Repeat("a", 64)}})
		}},
		{"capability_required", func(r *registry.Registry, _ *registry.Provider, _ registry.AppAttestServingAuthorization) {
			r.SetModelCatalog([]registry.CatalogEntry{{ID: appAttestTestModel, WeightHash: strings.Repeat("a", 64)}, {ID: "second-model", WeightHash: strings.Repeat("b", 64), RequiredProviderCapabilities: []string{registry.ProviderCapabilityMLXNAX}}})
		}},
		{"insufficient_memory", func(r *registry.Registry, _ *registry.Provider, _ registry.AppAttestServingAuthorization) {
			r.SetModelCatalog([]registry.CatalogEntry{{ID: appAttestTestModel, WeightHash: strings.Repeat("a", 64)}, {ID: "second-model", WeightHash: strings.Repeat("b", 64), MinRAMGB: 1024}})
		}},
		{"cleared_authorization", func(r *registry.Registry, p *registry.Provider, _ registry.AppAttestServingAuthorization) {
			r.ClearAppAttestServingAuthorization(p)
		}},
		{"older_authenticated_os", func(r *registry.Registry, p *registry.Provider, lease registry.AppAttestServingAuthorization) {
			lease.OSVersion = "26.4"
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant older authenticated OS")
			}
		}},
		{"malformed_authenticated_os", func(r *registry.Registry, p *registry.Provider, lease registry.AppAttestServingAuthorization) {
			lease.OSVersion = "27 beta"
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant malformed authenticated OS")
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r, p, lease := qualifiedAutopilotRewardProvider(t, false)
			if optedIn, supported, qualified := r.AutopilotRewardSnapshot(p); !optedIn || !supported || !qualified {
				t.Fatalf("complete downloaded selection did not qualify: %v/%v/%v", optedIn, supported, qualified)
			}
			tt.change(r, p, lease)
			if optedIn, supported, qualified := r.AutopilotRewardSnapshot(p); !optedIn || !supported || qualified {
				t.Fatalf("qualification failure changed saved consent or earned floor: %v/%v/%v", optedIn, supported, qualified)
			}
		})
	}
}

func TestAutopilotRewardQualificationCountsCachedInventoryWithoutControlLease(t *testing.T) {
	r, p, _ := qualifiedAutopilotRewardProvider(t, true)
	state := rewardConsentState()
	state.Enabled = true
	state.SelectedModels = []string{appAttestTestModel, "second-model"}
	state.Paused, state.ObserveOnly = true, true
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{ModelAutopilot: state}) {
		t.Fatal("accepted saved consent heartbeat")
	}
	if optedIn, supported, qualified := r.AutopilotRewardSnapshot(p); !optedIn || !supported || !qualified {
		t.Fatalf("cached inventory needed residency/control or erased saved consent: %v/%v/%v", optedIn, supported, qualified)
	}
	state.SelectedModels = state.SelectedModels[:1]
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{ModelAutopilot: state}) {
		t.Fatal("accepted inventory selection update")
	}
	if optedIn, supported, qualified := r.AutopilotRewardSnapshot(p); !optedIn || !supported || qualified {
		t.Fatalf("unselected cached model counted toward reward qualification: %v/%v/%v", optedIn, supported, qualified)
	}
}

func TestAutopilotRewardQualificationFencesExpiredAndReplacedConnections(t *testing.T) {
	clock := &appAttestTestClock{}
	r := registry.NewWithDependencies(testLogger(), registry.Dependencies{AppAttestNow: clock.Now})
	r, p, lease := appAttestTestProvider(t, r)
	p.ModelAutopilot = rewardConsentState()
	p.ModelAutopilot.Enabled = true
	p.ModelAutopilot.SelectedModels = []string{appAttestTestModel, "second-model"}
	p.Models = []protocol.ModelInfo{{ID: appAttestTestModel, WeightHash: "first"}, {ID: "second-model", WeightHash: "second"}}
	r.SetModelCatalog([]registry.CatalogEntry{{ID: appAttestTestModel, WeightHash: "first"}, {ID: "second-model", WeightHash: "second"}})
	lease.OSVersion = "27"
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant lease")
	}
	clock.Store(lease.ValidUntil.Add(time.Second).UnixNano())
	if optedIn, supported, qualified := r.AutopilotRewardSnapshot(p); !optedIn || !supported || qualified {
		t.Fatalf("expired lease qualified or erased saved consent: %v/%v/%v", optedIn, supported, qualified)
	}
	r.Disconnect(p.ID)
	r.Register(p.ID, nil, &protocol.RegisterMessage{ModelAutopilot: rewardConsentState()})
	if optedIn, supported, qualified := r.AutopilotRewardSnapshot(p); optedIn || supported || qualified {
		t.Fatal("old pointer acquired replacement connection's reward declaration")
	}
}

func TestAutopilotRewardDeclarationBoundsHardwareWithoutLosingConsent(t *testing.T) {
	for _, tc := range []struct {
		name   string
		chip   string
		memory int
		want   string
	}{
		{"ordinary", "Apple M3 Max", 64, "Apple M3 Max"},
		{"utf8_boundary", strings.Repeat("a", 127) + "é", 64, strings.Repeat("a", 127)},
		{"oversized", strings.Repeat("a", 129), 64, strings.Repeat("a", 128)},
		{"invalid_utf8", "Apple M3\xff", 64, ""},
		{"negative_memory", "Apple M3 Max", -1, "Apple M3 Max"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := registry.New(testLogger())
			p := r.Register(tc.name, nil, &protocol.RegisterMessage{ModelAutopilot: rewardConsentState()})
			p.Hardware.ChipName, p.Hardware.MemoryGB = tc.chip, tc.memory
			declaration := r.AutopilotRewardDeclaration(p)
			if declaration.Chip != tc.want || len(declaration.Chip) > 128 || !utf8.ValidString(declaration.Chip) || !declaration.OptedIn || !declaration.Supported || declaration.Qualified {
				t.Fatalf("hardware bounds changed consent or retained invalid data: %+v", declaration)
			}
			wantMemory := max(tc.memory, 0)
			if declaration.MemoryGB != float64(wantMemory) {
				t.Fatalf("memory = %v, want %v", declaration.MemoryGB, wantMemory)
			}
		})
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
