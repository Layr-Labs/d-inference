package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestColdModelLoadBlockedUsesLiveNoEvictionBudget(t *testing.T) {
	usable, headroom := 14.3, 6.5
	heartbeat := time.Now()
	accepted := []string{"qwen"}
	p := &myProvider{
		Online:           true,
		LastHeartbeat:    &heartbeat,
		CapacityModelIDs: &accepted,
		Models:           []protocol.ModelInfo{{ID: "qwen", EstimatedMemoryGB: 18.2}},
		BackendCapacity: &protocol.BackendCapacity{
			LoadUsableGB: &usable, LoadHeadroomGB: &headroom,
		},
	}
	noEviction := 7.8
	p.BackendCapacity.FreeForLoadGB = &noEviction
	stale := time.Now().Add(-2 * time.Minute)
	p.LastHeartbeat = &stale
	if coldModelLoadBlocked(p) {
		t.Fatal("stale heartbeat must withhold live load verdict")
	}
	p.LastHeartbeat = &heartbeat
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{Model: "small", State: "running", NumRunning: 1}}
	if coldModelLoadBlocked(p) {
		t.Fatal("active work makes cold-load memory verdict temporary")
	}
	p.BackendCapacity.Slots = nil
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
