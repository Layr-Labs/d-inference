package registry_test

import (
	"encoding/json"
	"log/slog"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func inventoryConsent(models ...string) *protocol.ModelAutopilotState {
	return &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true, Revision: "saved", SelectedModels: models}
}

func TestAutopilotInventoryCountsAndDisconnect(t *testing.T) {
	now := time.Now()
	r := production.NewWithDependencies(slog.New(slog.DiscardHandler), production.Dependencies{HeartbeatNow: func() time.Time { return now }})
	states := []*protocol.ModelAutopilotState{inventoryConsent("b", "a", "a"), inventoryConsent("c", "a"), inventoryConsent("b")}
	states[1].Paused = true
	for i, id := range []string{"first", "paused", "stale"} {
		r.Register(id, nil, &protocol.RegisterMessage{ModelAutopilot: states[i]})
		if i == 2 {
			now = now.Add(-2 * production.DefaultProviderHeartbeatTimeout)
		}
		r.Heartbeat(id, &protocol.HeartbeatMessage{ModelAutopilot: states[i], BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1}})
	}
	// A rejected sequence proves liveness but must not refresh stale selections.
	now = time.Now()
	r.Heartbeat("stale", &protocol.HeartbeatMessage{ModelAutopilot: inventoryConsent("rejected"), BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1}})
	report := r.AutopilotInventory()
	if report.EnrolledProviders != 3 || report.ParticipatingProviders != 2 || report.PausedProviders != 1 || report.StaleProviders != 1 || report.DistinctModels != 3 || report.TotalApprovals != 5 || report.StaleAfterSeconds != 90 {
		t.Fatalf("unexpected totals: %+v", report)
	}
	wantModels := []production.AutopilotInventoryModel{
		{ModelID: "a", ApprovedProviders: 2, ParticipatingProviders: 1, PausedProviders: 1},
		{ModelID: "b", ApprovedProviders: 2, ParticipatingProviders: 2, StaleProviders: 1},
		{ModelID: "c", ApprovedProviders: 1, PausedProviders: 1},
	}
	if !reflect.DeepEqual(report.Models, wantModels) || !reflect.DeepEqual(report.ModelsPerProvider, []production.AutopilotInventoryDistribution{{ModelCount: 1, ProviderCount: 1}, {ModelCount: 2, ProviderCount: 2}}) {
		t.Fatalf("unexpected inventory: %+v", report)
	}
	// Snapshot values are detached and reads do not mutate provider state.
	before, _ := json.Marshal(r.GetProvider("first").ModelAutopilot)
	report.Models[0].ModelID = "mutated"
	for range 3 {
		if got := r.AutopilotInventory(); !reflect.DeepEqual(got.Models, wantModels) {
			t.Fatalf("read changed inventory: %+v", got)
		}
	}
	after, _ := json.Marshal(r.GetProvider("first").ModelAutopilot)
	if string(before) != string(after) {
		t.Fatal("inventory read mutated consent")
	}
	r.Disconnect("first")
	if got := r.AutopilotInventory(); got.EnrolledProviders != 2 || got.TotalApprovals != 3 {
		t.Fatalf("disconnected connection retained: %+v", got)
	}
	r.Disconnect("paused")
	r.Disconnect("stale")
	if got := r.AutopilotInventory(); got.EnrolledProviders != 0 || got.Models == nil || got.ModelsPerProvider == nil || len(got.Models) != 0 || len(got.ModelsPerProvider) != 0 {
		t.Fatalf("empty report: %+v", got)
	}
}

func TestAutopilotInventoryConsentGates(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*protocol.RegisterMessage)
	}{
		{"absent", func(m *protocol.RegisterMessage) { m.ModelAutopilot = nil }},
		{"disabled", func(m *protocol.RegisterMessage) { m.ModelAutopilot.Enabled = false }},
		{"private", func(m *protocol.RegisterMessage) { m.PrivateOnly = true }},
		{"unsupported", func(m *protocol.RegisterMessage) { m.ModelAutopilot.Protocol++ }},
		{"not cached only", func(m *protocol.RegisterMessage) { m.ModelAutopilot.CachedOnly = false }},
		{"no revision", func(m *protocol.RegisterMessage) { m.ModelAutopilot.Revision = "" }},
		{"empty selection", func(m *protocol.RegisterMessage) { m.ModelAutopilot.SelectedModels = nil }},
		{"blank model", func(m *protocol.RegisterMessage) { m.ModelAutopilot.SelectedModels = []string{"hidden", ""} }},
		{"oversize selection", func(m *protocol.RegisterMessage) { m.ModelAutopilot.SelectedModels = make([]string, 257) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := production.New(slog.New(slog.DiscardHandler))
			msg := &protocol.RegisterMessage{ModelAutopilot: inventoryConsent("hidden")}
			tc.change(msg)
			r.Register("connection", nil, msg)
			if got := r.AutopilotInventory(); got.EnrolledProviders != 0 || got.TotalApprovals != 0 {
				t.Fatalf("excluded state leaked: %+v", got)
			}
		})
	}
}

func TestAutopilotInventoryRegistrationAndOptOut(t *testing.T) {
	r := production.New(slog.New(slog.DiscardHandler))
	state := inventoryConsent("saved")
	state.ObserveOnly = true
	r.Register("connection", nil, &protocol.RegisterMessage{ModelAutopilot: state})
	if got := r.AutopilotInventory(); got.EnrolledProviders != 1 || got.ParticipatingProviders != 1 || got.StaleProviders != 1 {
		t.Fatalf("registration-only shadow inventory: %+v", got)
	}
	r.Heartbeat("connection", &protocol.HeartbeatMessage{})
	if got := r.AutopilotInventory(); got.EnrolledProviders != 0 {
		t.Fatalf("omitted state not cleared: %+v", got)
	}
}

func TestAutopilotInventoryConcurrentHeartbeat(t *testing.T) {
	r := production.New(slog.New(slog.DiscardHandler))
	r.Register("connection", nil, &protocol.RegisterMessage{ModelAutopilot: inventoryConsent("a")})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for seq := uint64(1); seq <= 100; seq++ {
			state := inventoryConsent("b", "a", "b")
			state.Paused = seq%2 == 0
			r.Heartbeat("connection", &protocol.HeartbeatMessage{ModelAutopilot: state, BackendCapacity: &protocol.BackendCapacity{CapacitySeq: seq}})
		}
		r.Disconnect("connection")
	}()
	for range 100 {
		got := r.AutopilotInventory()
		if got.EnrolledProviders != got.PausedProviders+got.ParticipatingProviders {
			t.Errorf("inconsistent provider totals: %+v", got)
		}
		total := 0
		for _, model := range got.Models {
			total += model.ApprovedProviders
		}
		if total != got.TotalApprovals {
			t.Errorf("inconsistent approvals: %+v", got)
		}
	}
	wg.Wait()
}
