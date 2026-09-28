package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestMyProviderExportsCapacityAcceptedAt(t *testing.T) {
	accepted := time.Now().Add(-time.Minute)
	live := &registry.Provider{
		ID: "p1", Status: registry.StatusServing,
		LastHeartbeat: time.Now(), CapacityAcceptedAt: accepted,
		BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{}},
	}
	owner := buildMyProvider(nil, live)
	if owner.CapacityAcceptedAt == nil || !owner.CapacityAcceptedAt.Equal(accepted) {
		t.Fatalf("owner capacity time = %v, want %v", owner.CapacityAcceptedAt, accepted)
	}
	if owner.LastHeartbeat == nil || !owner.LastHeartbeat.After(accepted) {
		t.Fatal("liveness and accepted-capacity timestamps were conflated")
	}
}

func TestColdModelLoadBlockedUsesLiveNoEvictionBudget(t *testing.T) {
	usable, headroom := 14.3, 6.5
	heartbeat := time.Now()
	accepted := []string{"qwen"}
	p := &myProvider{
		Online:             true,
		LastHeartbeat:      &heartbeat,
		CapacityAcceptedAt: &heartbeat,
		CapacityModelIDs:   &accepted,
		Models:             []protocol.ModelInfo{{ID: "qwen", EstimatedMemoryGB: 18.2}},
		BackendCapacity: &protocol.BackendCapacity{
			LoadUsableGB: &usable, LoadHeadroomGB: &headroom,
		},
	}
	noEviction := 7.8
	p.BackendCapacity.FreeForLoadGB = &noEviction
	stale := time.Now().Add(-2 * time.Minute)
	p.CapacityAcceptedAt = &stale
	if coldModelLoadBlocked(p) {
		t.Fatal("stale accepted capacity must withhold verdict despite fresh heartbeat")
	}
	p.CapacityAcceptedAt = &heartbeat
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{Model: "small", State: "running", NumRunning: 1}}
	if coldModelLoadBlocked(p) {
		t.Fatal("active work makes cold-load memory verdict temporary")
	}
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{Model: "small", State: "idle", NumWaiting: 1}}
	if coldModelLoadBlocked(p) {
		t.Fatal("queued slot work makes cold-load memory verdict temporary")
	}
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{Model: "qwen", State: "reloading"}}
	if coldModelLoadBlocked(p) {
		t.Fatal("reloading slot makes memory verdict temporary")
	}
	p.BackendCapacity.Slots = nil
	loading := true
	p.BackendCapacity.LoadTransitionActive = &loading
	if coldModelLoadBlocked(p) {
		t.Fatal("in-flight load without a slot makes memory verdict temporary")
	}
	loading = false
	if !coldModelLoadBlocked(p) {
		t.Fatal("24.7 GB requirement must be blocked by 14.3 GB usable")
	}
	mayEvict := 19.0
	p.BackendCapacity.FreeForLoadGB = &mayEvict
	if coldModelLoadBlocked(p) {
		t.Fatal("request-time eviction can load the model; no blocking fleet warning")
	}
	p.BackendCapacity.FreeForLoadGB = nil
	if coldModelLoadBlocked(p) {
		t.Fatal("missing eviction-aware allowance leaves cold-load outcome unknown")
	}
	p.BackendCapacity.FreeForLoadGB = &noEviction
	p.WarmModels = []string{"qwen"}
	if !coldModelLoadBlocked(p) {
		t.Fatal("stale warm_models cannot override empty authoritative slots")
	}
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{Model: "qwen", State: "idle"}}
	if coldModelLoadBlocked(p) {
		t.Fatal("resident capacity slot needs no cold load")
	}
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{Model: "qwen", State: "crashed"}}
	if coldModelLoadBlocked(p) {
		t.Fatal("crashed resident slot needs a backend warning, not a cold-load warning")
	}
	p.BackendCapacity.Slots = nil
	p.WarmModels = nil
	p.Models = []protocol.ModelInfo{{ID: "off-catalog", EstimatedMemoryGB: 18.2}}
	if coldModelLoadBlocked(p) {
		t.Fatal("off-catalog model lacks accepted capacity evidence")
	}
	p.Models = []protocol.ModelInfo{{ID: "qwen", EstimatedMemoryGB: 18.2}}
	p.BackendCapacity.LoadUsableGB = nil
	if coldModelLoadBlocked(p) {
		t.Fatal("older provider without live budget has unknown readiness")
	}
}
