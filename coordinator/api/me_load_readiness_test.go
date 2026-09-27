package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestColdModelLoadBlockedUsesLiveNoEvictionBudget(t *testing.T) {
	usable, headroom := 14.3, 6.5
	p := &myProvider{
		Online: true,
		Models: []protocol.ModelInfo{{ID: "qwen", EstimatedMemoryGB: 18.2}},
		BackendCapacity: &protocol.BackendCapacity{
			LoadUsableGB: &usable, LoadHeadroomGB: &headroom,
		},
	}
	noEviction := 7.8
	p.BackendCapacity.FreeForLoadGB = &noEviction
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
	if coldModelLoadBlocked(p) {
		t.Fatal("resident model needs no cold load")
	}
	p.WarmModels = nil
	p.BackendCapacity.LoadUsableGB = nil
	if coldModelLoadBlocked(p) {
		t.Fatal("older provider without live budget has unknown readiness")
	}
}
