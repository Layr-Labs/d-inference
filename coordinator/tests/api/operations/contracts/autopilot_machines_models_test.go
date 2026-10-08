package operations_test

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestAutopilotMachinesHeartbeatModelReports(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	reg, _, server := newAutopilotMachineHTTP(t, st)
	id := observeAutopilotMachine(t, st, "model-report")
	hardware := protocol.Hardware{MachineModel: "Mac16,3", ChipName: "Apple M4", MemoryGB: 32}
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "advertised-only"}, {ID: "warm-only"}, {ID: "slot-only"}})
	p := reg.Register("model-report", nil, &protocol.RegisterMessage{
		Hardware: hardware,
		Models:   []protocol.ModelInfo{{ID: "advertised-only"}, {ID: "warm-only"}, {ID: "slot-only"}},
	})
	p.Mu().Lock()
	p.AccountID = "private-owner"
	p.Mu().Unlock()
	if !reg.BindVerifiedMachineIdentity(p, "private-owner", id) {
		t.Fatal("verified binding rejected")
	}
	// Pins include an implicit pin outside the saved selection. Autopilot
	// residency deliberately differs from both warm models and backend slots.
	report := &protocol.ModelAutopilotState{
		Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true, Paused: true,
		Revision: "private-consent-revision", SessionID: "private-consent-session",
		SelectedModels: []string{"z-explicit-pin", "selected-only"},
		PinnedModels:   []string{"z-explicit-pin", "a-implicit-pin"},
		ResidentModels: []protocol.ModelAutopilotResident{{ModelID: "z-resident", WeightsGB: 2}, {ModelID: "a-resident", WeightsGB: 1}},
		LoadHistory:    []protocol.ModelAutopilotLoadTiming{{ModelID: "selected-only", WeightHash: "private-load-hash"}},
		LastCommandID:  "private-last-command", LastCommandStatus: "private-command-status",
	}
	if !reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Status: "idle", ModelAutopilot: report, IdleUnloadMins: new(30),
		WarmModels: []string{"warm-only"}, ActiveModel: new("warm-only"),
		BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1, Slots: []protocol.BackendSlotCapacity{{Model: "slot-only", State: "idle"}}},
	}) {
		t.Fatal("heartbeat rejected")
	}
	p.Mu().Lock()
	lastHeartbeat, capacityAcceptedAt := p.LastHeartbeat, p.CapacityAcceptedAt
	warmModels, currentModel := p.WarmModels, p.CurrentModel
	p.Mu().Unlock()
	if !reflect.DeepEqual(warmModels, []string{"warm-only"}) || currentModel != "warm-only" {
		t.Fatalf("fixture lost ordinary model state: warm=%v active=%q", warmModels, currentModel)
	}
	machine := patchAutopilotMachine(t, server, id, store.MachineAutopilotLive)
	if machine.DesiredMode != store.MachineAutopilotLive || machine.Revision != 1 || len(machine.Sessions) != 1 {
		t.Fatalf("PATCH lost intent or verified report: %+v", machine)
	}
	session := machine.Sessions[0]
	if session.MachineModel != hardware.MachineModel || session.ChipName != hardware.ChipName || session.MemoryGB != hardware.MemoryGB {
		t.Fatalf("session hardware missing: %+v", session)
	}
	if session.LastHeartbeat == nil || !session.LastHeartbeat.Equal(lastHeartbeat) || session.CapacityAcceptedAt == nil || !session.CapacityAcceptedAt.Equal(capacityAcceptedAt) {
		t.Fatalf("session freshness does not match accepted heartbeat: %+v", session)
	}
	if session.IdleUnloadMins == nil || *session.IdleUnloadMins != 30 || session.AlwaysReadyConfigured == nil || *session.AlwaysReadyConfigured {
		t.Fatalf("positive idle timeout is not always-ready configuration: %+v", session)
	}
	if !reflect.DeepEqual(session.PinnedModels, []string{"a-implicit-pin", "z-explicit-pin"}) || !reflect.DeepEqual(session.ResidentModels, []string{"a-resident", "z-resident"}) {
		t.Fatalf("model reports were filtered, substituted or unsorted: %+v", session)
	}
	if session.EffectiveMode != "disabled" || session.ControlActive || !session.Paused {
		t.Fatalf("model reports activated control or cleared provider pause: %+v", session)
	}
	body := autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath, autopilotMachinesAdminKey, "", http.StatusOK)
	var page autopilotMachinePage
	if err := json.Unmarshal(body, &page); err != nil || len(page.Machines) != 1 || !reflect.DeepEqual(page.Machines[0], machine) {
		t.Fatalf("GET changed intent, reports or timestamps: %s (%v)", body, err)
	}
	for _, secret := range []string{"private-owner", "private-se-", "private-serial-", "private-app-attest-", "private-consent-revision", "private-consent-session", "private-load-hash", "private-last-command", "private-command-status", "selected-only", "advertised-only", "warm-only", "slot-only", autopilotMachinesAdminKey} {
		if strings.Contains(string(body), secret) {
			t.Fatalf("machine projection leaked unrelated metadata %q: %s", secret, body)
		}
	}
	p.Mu().Lock()
	unchanged := reflect.DeepEqual(p.ModelAutopilot, report) && p.IdleUnloadMins != nil && *p.IdleUnloadMins == 30
	p.Mu().Unlock()
	if !unchanged {
		t.Fatal("reading machine projection changed provider reports or policy")
	}
}

func TestAutopilotMachinesModelReportUnknownAndEmpty(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		state                   *protocol.ModelAutopilotState
		wantPins, wantResidents string
	}{
		{name: "missing", wantPins: "null", wantResidents: "null"},
		{name: "unsupported protocol", state: &protocol.ModelAutopilotState{
			Protocol: protocol.ModelAutopilotProtocol - 1, Enabled: true, CachedOnly: true,
			PinnedModels: []string{"unsupported-pin"}, ResidentModels: []protocol.ModelAutopilotResident{{ModelID: "unsupported-resident"}},
		}, wantPins: "null", wantResidents: "null"},
		{name: "not cached only", state: &protocol.ModelAutopilotState{
			Protocol: protocol.ModelAutopilotProtocol, Enabled: true,
			PinnedModels: []string{"unsupported-pin"}, ResidentModels: []protocol.ModelAutopilotResident{{ModelID: "unsupported-resident"}},
		}, wantPins: "null", wantResidents: "null"},
		{name: "sanitized malformed snapshot", state: &protocol.ModelAutopilotState{
			Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true,
			PinnedModels: []string{strings.Repeat("x", 257)}, ResidentModels: []protocol.ModelAutopilotResident{{ModelID: "discarded-resident"}},
		}, wantPins: "null", wantResidents: "null"},
		{name: "known empty", state: &protocol.ModelAutopilotState{
			Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true, SelectedModels: []string{"selected-only"},
		}, wantPins: "[]", wantResidents: "[]"},
		{name: "disabled provider still reports", state: &protocol.ModelAutopilotState{
			Protocol: protocol.ModelAutopilotProtocol, CachedOnly: true,
			PinnedModels: []string{"reported-pin"}, ResidentModels: []protocol.ModelAutopilotResident{{ModelID: "reported-resident"}},
		}, wantPins: `["reported-pin"]`, wantResidents: `["reported-resident"]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := memory.NewMemory(store.Config{})
			reg, _, server := newAutopilotMachineHTTP(t, st)
			id := observeAutopilotMachine(t, st, "nullable-report")
			reg.SetModelCatalog([]registry.CatalogEntry{{ID: "ordinary-model"}})
			p := reg.Register("nullable-report", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "ordinary-model"}}})
			p.Mu().Lock()
			p.AccountID = "private-owner"
			p.Mu().Unlock()
			if !reg.BindVerifiedMachineIdentity(p, "private-owner", id) {
				t.Fatal("verified binding rejected")
			}
			if !reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{
				ModelAutopilot: tc.state, WarmModels: []string{"ordinary-model"},
				BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1, Slots: []protocol.BackendSlotCapacity{{Model: "ordinary-model", State: "idle"}}},
			}) {
				t.Fatal("heartbeat rejected")
			}
			body := autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath, autopilotMachinesAdminKey, "", http.StatusOK)
			var raw struct {
				Machines []struct {
					Sessions []map[string]json.RawMessage `json:"sessions"`
				} `json:"machines"`
			}
			if err := json.Unmarshal(body, &raw); err != nil || len(raw.Machines) != 1 || len(raw.Machines[0].Sessions) != 1 {
				t.Fatalf("unexpected machine report: %s (%v)", body, err)
			}
			for field, want := range map[string]string{
				"pinned_models": tc.wantPins, "resident_models": tc.wantResidents,
				"idle_unload_mins": "null", "always_ready_configured": "null",
				"machine_model": `""`, "chip_name": `""`, "memory_gb": "0",
			} {
				if got := string(raw.Machines[0].Sessions[0][field]); got != want {
					t.Fatalf("%s=%s want=%s; body=%s", field, got, want, body)
				}
			}
		})
	}
}

func TestAutopilotMachinesHeartbeatOrderAndReconnect(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	logger := slog.New(slog.DiscardHandler)
	acceptedAt := time.Now().UTC().Add(-2 * time.Minute)
	reg := registry.NewWithDependencies(logger, registry.Dependencies{HeartbeatNow: func() time.Time { return acceptedAt }})
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{AdminKey: autopilotMachinesAdminKey}, logger)
	server := httptest.NewServer(srv.Handler())
	t.Cleanup(server.Close)
	id := observeAutopilotMachine(t, st, "ordered-report")
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "ordinary-model"}})
	capacity := func(seq uint64) *protocol.BackendCapacity {
		return &protocol.BackendCapacity{CapacitySeq: seq, Slots: []protocol.BackendSlotCapacity{{Model: "ordinary-model", State: "idle"}}}
	}
	p := reg.Register("ordered-report", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "ordinary-model"}}})
	p.Mu().Lock()
	p.AccountID = "private-owner"
	p.Mu().Unlock()
	if !reg.BindVerifiedMachineIdentity(p, "private-owner", id) {
		t.Fatal("verified binding rejected")
	}
	if !reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		IdleUnloadMins: new(0), BackendCapacity: capacity(2),
		ModelAutopilot: &protocol.ModelAutopilotState{
			Protocol: protocol.ModelAutopilotProtocol, CachedOnly: true, Paused: true,
			PinnedModels: []string{"accepted-pin"}, ResidentModels: []protocol.ModelAutopilotResident{{ModelID: "accepted-resident"}},
		},
	}) {
		t.Fatal("initial heartbeat rejected")
	}
	patchAutopilotMachine(t, server, id, store.MachineAutopilotLive)
	initial := onlyAutopilotMachineSession(t, server, id)
	if initial.LastHeartbeat == nil || !initial.LastHeartbeat.Equal(acceptedAt) || initial.CapacityAcceptedAt == nil || !initial.CapacityAcceptedAt.Equal(acceptedAt) || initial.CapacityFresh {
		t.Fatalf("old accepted capacity was refreshed by an HTTP read: %+v", initial)
	}
	for _, seq := range []uint64{1, 2} {
		if reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{
			IdleUnloadMins: new(30), BackendCapacity: capacity(seq),
			ModelAutopilot: &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, CachedOnly: true, PinnedModels: []string{"stale-pin"}},
		}) {
			t.Fatalf("stale heartbeat %d accepted", seq)
		}
		p.Mu().Lock()
		lastHeartbeat := p.LastHeartbeat
		p.Mu().Unlock()
		got := onlyAutopilotMachineSession(t, server, id)
		if got.LastHeartbeat == nil || !got.LastHeartbeat.Equal(lastHeartbeat) || !got.LastHeartbeat.After(acceptedAt) {
			t.Fatalf("stale frame did not retain its liveness timestamp: %+v", got)
		}
		got.LastHeartbeat = initial.LastHeartbeat
		if !reflect.DeepEqual(got, initial) {
			t.Fatalf("stale frame regressed reports or refreshed capacity: got=%+v want=%+v", got, initial)
		}
	}
	for i, idle := range []*int{nil, new(-1)} {
		acceptedAt = time.Now().UTC()
		if !reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{
			IdleUnloadMins: idle, BackendCapacity: capacity(uint64(3 + i)),
			ModelAutopilot: &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, CachedOnly: true},
		}) {
			t.Fatal("newer heartbeat rejected")
		}
		got := onlyAutopilotMachineSession(t, server, id)
		if got.LastHeartbeat == nil || !got.LastHeartbeat.Equal(acceptedAt) || got.CapacityAcceptedAt == nil || !got.CapacityAcceptedAt.Equal(acceptedAt) || !got.CapacityFresh {
			t.Fatalf("newer heartbeat freshness missing: %+v", got)
		}
		if got.PinnedModels == nil || len(got.PinnedModels) != 0 || got.ResidentModels == nil || len(got.ResidentModels) != 0 || got.Paused || got.ControlActive {
			t.Fatalf("newer empty report was not authoritative: %+v", got)
		}
		if got.IdleUnloadMins == nil || *got.IdleUnloadMins != 0 || got.AlwaysReadyConfigured == nil || !*got.AlwaysReadyConfigured {
			t.Fatalf("omitted or invalid idle policy cleared the connection policy: %+v", got)
		}
	}
	if !reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{}) {
		t.Fatal("capacity-omitting heartbeat rejected")
	}
	cleared := onlyAutopilotMachineSession(t, server, id)
	if cleared.PinnedModels != nil || cleared.ResidentModels != nil || cleared.CapacityAcceptedAt != nil || cleared.CapacityFresh || cleared.LastHeartbeat == nil || !cleared.LastHeartbeat.Equal(acceptedAt) || cleared.IdleUnloadMins == nil || *cleared.IdleUnloadMins != 0 {
		t.Fatalf("omitted reports retained stale models/capacity or lost sticky idle policy: %+v", cleared)
	}
	reg.Disconnect(p.ID)
	for _, reconnect := range []bool{false, true} {
		if reconnect {
			p = reg.Register("reconnected-report", nil, &protocol.RegisterMessage{
				Hardware: protocol.Hardware{MachineModel: "Mac14,13", ChipName: "Apple M2 Max", MemoryGB: 64},
				Models:   []protocol.ModelInfo{{ID: "ordinary-model"}},
			})
			p.Mu().Lock()
			p.AccountID = "private-owner"
			p.Mu().Unlock()
		}
		page := listAutopilotMachines(t, server, "")
		if len(page.Machines) != 1 || page.Machines[0].DesiredMode != store.MachineAutopilotLive || page.Machines[0].Revision != 1 || page.Machines[0].Sessions == nil || len(page.Machines[0].Sessions) != 0 {
			t.Fatalf("offline/unverified reconnect lost intent or retained reports: %+v", page)
		}
	}
	if !reg.BindVerifiedMachineIdentity(p, "private-owner", id) {
		t.Fatal("reconnected verified binding rejected")
	}
	reconnected := onlyAutopilotMachineSession(t, server, id)
	if reconnected.ProviderID != "reconnected-report" || reconnected.MachineModel != "Mac14,13" || reconnected.ChipName != "Apple M2 Max" || reconnected.MemoryGB != 64 || reconnected.LastHeartbeat == nil || reconnected.CapacityAcceptedAt != nil || reconnected.IdleUnloadMins != nil || reconnected.AlwaysReadyConfigured != nil || reconnected.PinnedModels != nil || reconnected.ResidentModels != nil {
		t.Fatalf("reconnect inherited old reports instead of new session hardware: %+v", reconnected)
	}
	if !reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		IdleUnloadMins: new(30), BackendCapacity: capacity(1),
		ModelAutopilot: &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, CachedOnly: true, PinnedModels: []string{"reconnected-pin"}},
	}) {
		t.Fatal("new connection did not reset sequence ordering")
	}
	reconnected = onlyAutopilotMachineSession(t, server, id)
	if reconnected.IdleUnloadMins == nil || *reconnected.IdleUnloadMins != 30 || reconnected.AlwaysReadyConfigured == nil || *reconnected.AlwaysReadyConfigured || !reflect.DeepEqual(reconnected.PinnedModels, []string{"reconnected-pin"}) || reconnected.ResidentModels == nil || len(reconnected.ResidentModels) != 0 {
		t.Fatalf("new connection policy not projected: %+v", reconnected)
	}
}

func TestAutopilotMachinesModelReportsRequireCurrentVerifiedOwner(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	reg, _, server := newAutopilotMachineHTTP(t, st)
	id := observeAutopilotMachine(t, st, "identity-report")
	for _, providerID := range []string{"private-provider", "unverified-provider", "changed-owner-provider"} {
		p := reg.Register(providerID, nil, &protocol.RegisterMessage{PrivateOnly: providerID == "private-provider"})
		p.Mu().Lock()
		p.AccountID = "private-owner"
		p.Mu().Unlock()
		if providerID != "unverified-provider" && !reg.BindVerifiedMachineIdentity(p, "private-owner", id) {
			t.Fatal("verified binding rejected")
		}
		if providerID == "changed-owner-provider" {
			p.Mu().Lock()
			p.AccountID = "other-owner"
			p.Mu().Unlock()
		}
		if !reg.Heartbeat(providerID, &protocol.HeartbeatMessage{
			IdleUnloadMins: new(0), ModelAutopilot: &protocol.ModelAutopilotState{
				Protocol: protocol.ModelAutopilotProtocol, CachedOnly: true,
				PinnedModels: []string{providerID + "-pin"}, ResidentModels: []protocol.ModelAutopilotResident{{ModelID: providerID + "-resident"}},
			},
		}) {
			t.Fatal("heartbeat rejected")
		}
	}
	session := onlyAutopilotMachineSession(t, server, id)
	if session.ProviderID != "private-provider" || !session.PrivateOnly || !reflect.DeepEqual(session.PinnedModels, []string{"private-provider-pin"}) || !reflect.DeepEqual(session.ResidentModels, []string{"private-provider-resident"}) {
		t.Fatalf("private report missing or joined to a different owner/session: %+v", session)
	}
	body := autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath, autopilotMachinesAdminKey, "", http.StatusOK)
	for _, secret := range []string{"unverified-provider", "changed-owner-provider", "private-owner", "other-owner"} {
		if strings.Contains(string(body), secret) {
			t.Fatalf("machine report leaked an unbound report or account %q: %s", secret, body)
		}
	}
	ownerKey, err := st.CreateKeyForAccount("private-owner")
	if err != nil {
		t.Fatal(err)
	}
	body = autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath, ownerKey, "", http.StatusForbidden)
	if strings.Contains(string(body), "private-provider") || strings.Contains(string(body), id) {
		t.Fatalf("non-admin owner received machine reports: %s", body)
	}
}

func onlyAutopilotMachineSession(t *testing.T, server *httptest.Server, machineID string) registry.MachineAutopilotSession {
	t.Helper()
	page := listAutopilotMachines(t, server, "")
	if len(page.Machines) != 1 || page.Machines[0].MachineID != machineID || len(page.Machines[0].Sessions) != 1 {
		t.Fatalf("expected one verified session for machine %s: %+v", machineID, page)
	}
	return page.Machines[0].Sessions[0]
}
