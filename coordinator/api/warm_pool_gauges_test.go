package api

import (
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestWarmPoolColdDisqualifierGauges verifies the warm-pool eligibility
// diagnostics reach Datadog: per-model eligible_cold / cold_ineligible gauges
// and the per-(model, reason) cold_disqualified tally, emitted from the
// controller's latest snapshots by the same gauge loop that pushes the fleet
// and utilization gauges. This is the "why is eligible_cold 0" dashboard
// (postmortem 2026-07-06 §3.3) — asserted against a live UDP DogStatsD
// collector.
func TestWarmPoolColdDisqualifierGauges(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	model := "gauge-cold-model"
	// A cold provider for `model` (no backend slot for it) that is BUSY serving a
	// co-resident model: disqualified from warming with reason not_idle.
	p := makeRoutableProvider(t, reg, "busy-cold-box", model)
	p.Mu().Lock()
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
		{Model: "co-resident-model", State: "running", NumRunning: 1},
	}
	p.Mu().Unlock()

	reg.ConfigureWarmPool(registry.WarmPoolConfig{
		Enabled:                    true,
		Interval:                   time.Second,
		CapacityRejectThreshold:    1,
		TTFTMissThreshold:          1,
		SpeculativeStartThreshold:  1,
		SpeculativeWinThreshold:    1,
		ColdDispatchThreshold:      1,
		FallbackQualityConcurrency: 4,
		MaxLoadsPerTick:            1,
		MaxLoadsPerTickCeiling:     4,
		MaxGlobalPendingLoads:      4,
	})
	snaps := reg.TriggerWarmPool()
	found := false
	for _, s := range snaps {
		if s.Model == model && s.ColdIneligible == 1 && s.ColdDisqualifiers["not_idle"] == 1 {
			found = true
		}
	}
	if !found {
		t.Fatalf("warm-pool snapshots missing the not_idle disqualifier for %s: %+v", model, snaps)
	}

	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetDatadog(dd)

	srv.pushDDGauges()
	_ = dd.Statsd.Flush()
	packets := collector.drain()

	disq := findMetrics(packets, "warm_pool.cold_disqualified")
	if len(disq) == 0 {
		t.Fatalf("no warm_pool.cold_disqualified gauge; packets: %v", packets)
	}
	tagged := false
	for _, pkt := range disq {
		if strings.Contains(pkt, "model:"+model) && strings.Contains(pkt, "reason:not_idle") {
			tagged = true
		}
	}
	if !tagged {
		t.Fatalf("warm_pool.cold_disqualified missing (model, reason) tags; packets: %v", disq)
	}

	eligible := findMetrics(packets, "warm_pool.eligible_cold")
	if len(eligible) == 0 || !strings.Contains(strings.Join(eligible, "\n"), "model:"+model) {
		t.Fatalf("no per-model warm_pool.eligible_cold gauge; packets: %v", packets)
	}
	ineligible := findMetrics(packets, "warm_pool.cold_ineligible")
	if len(ineligible) == 0 || !strings.Contains(strings.Join(ineligible, "\n"), "model:"+model) {
		t.Fatalf("no per-model warm_pool.cold_ineligible gauge; packets: %v", packets)
	}
}
