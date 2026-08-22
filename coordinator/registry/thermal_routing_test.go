package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Thermal state is macOS's own ProcessInfo.thermalState, forwarded verbatim by
// the provider (SystemMetrics.swift). Darkbloom sets no temperature threshold,
// so the only thing under our control is what each of Apple's four states costs
// a provider. These tests pin that contract against the real scheduler, because
// the operator-facing dashboard copy quotes it and drifted once already.
//
//	nominal  -> free
//	fair     -> +2s of cost, inside the 3s near-tie window (keeps competing)
//	serious  -> +8s of cost, outside the window (loses to an equal cooler peer)
//	critical -> hard exclusion

func setThermalState(t *testing.T, p *Provider, state string) {
	t.Helper()
	p.mu.Lock()
	p.SystemMetrics.ThermalState = state
	p.mu.Unlock()
}

// reserveAndRelease routes one request and immediately releases the reservation
// so every input the cost function reads is identical on the next call. Returns
// the winning provider ID, or "" when nothing was selected.
func reserveAndRelease(reg *Registry, model string, i int) string {
	pr := &PendingRequest{
		RequestID:          fmt.Sprintf("thermal-req-%d", i),
		Model:              model,
		RequestedMaxTokens: 256,
	}
	p := reg.ReserveProvider(model, pr)
	if p == nil {
		return ""
	}
	p.RemovePending(pr.RequestID)
	reg.SetProviderIdle(p.ID)
	return p.ID
}

// A `fair` machine costs 2s more than an identical `nominal` peer, which is
// inside nearTieCostWindowMs (3s). Both therefore enter the near-tie set, tie on
// queue depth and pending count, and are spread randomly — so `fair` alone costs
// an otherwise-equal WARM machine no dispatches. (It is not free everywhere: the
// warm-pool preload ranks cold candidates by strict score with no tie window, so
// `fair` loses a pre-warm tie-break by 250 points. The dashboard says both.)
// This is the claim the provider dashboard makes; if the penalty is ever raised
// past the tie window, the dashboard is lying and this test must fail.
func TestThermalFairKeepsCompetingWithNominalPeer(t *testing.T) {
	if thermalPenaltyFairMs > nearTieCostWindowMs {
		t.Fatalf("thermalPenaltyFairMs (%.0f) exceeds nearTieCostWindowMs (%.0f): "+
			"`fair` now costs real traffic, so the dashboard copy calling it "+
			"informational must be updated too", thermalPenaltyFairMs, nearTieCostWindowMs)
	}

	reg := New(testLogger())
	model := "thermal-fair-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{id: "cool", decodeTPS: 60, totalMemGB: 64, gpuActiveGB: 8}.register(t, reg, model)
	warm := scenarioProvider{id: "warm", decodeTPS: 60, totalMemGB: 64, gpuActiveGB: 8}.register(t, reg, model)
	setThermalState(t, warm, "fair")

	const trials = 400
	wins := map[string]int{}
	for i := range trials {
		wins[reserveAndRelease(reg, model, i)]++
	}

	if wins[""] != 0 {
		t.Fatalf("%d/%d requests selected no provider", wins[""], trials)
	}
	// Random spread across two equivalent candidates is ~50/50; anything above
	// a third proves `fair` did not drop out of contention. The bound is loose
	// enough that flakes are not credible: at p=0.5 over 400 trials, sigma is
	// 10, so the 133-win floor sits ~6.7 sigma below the mean.
	if wins["warm"] < trials/3 {
		t.Fatalf("fair provider won %d/%d — a %.0fms penalty inside the %.0fms "+
			"near-tie window must not push it out of the random spread",
			wins["warm"], trials, thermalPenaltyFairMs, nearTieCostWindowMs)
	}
}

// `serious` costs 8s, which clears the 3s near-tie window, so an otherwise
// identical cooler peer wins every time. It is still a cost term, not a gate:
// the hot machine remains selectable when it is the only candidate.
func TestThermalSeriousLosesToNominalPeerButStaysEligible(t *testing.T) {
	if thermalPenaltySeriousMs <= nearTieCostWindowMs {
		t.Fatalf("thermalPenaltySeriousMs (%.0f) no longer clears nearTieCostWindowMs (%.0f)",
			thermalPenaltySeriousMs, nearTieCostWindowMs)
	}

	reg := New(testLogger())
	model := "thermal-serious-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{id: "cool", decodeTPS: 60, totalMemGB: 64, gpuActiveGB: 8}.register(t, reg, model)
	hot := scenarioProvider{id: "hot", decodeTPS: 60, totalMemGB: 64, gpuActiveGB: 8}.register(t, reg, model)
	setThermalState(t, hot, "serious")

	for i := range 50 {
		if got := reserveAndRelease(reg, model, i); got != "cool" {
			t.Fatalf("trial %d selected %q, want cool: an 8s thermal penalty must "+
				"beat an otherwise-identical peer out of the tie window", i, got)
		}
	}

	// Sole candidate: still routable, just expensive.
	solo := New(testLogger())
	soloModel := "thermal-serious-solo"
	solo.SetModelCatalog([]CatalogEntry{{ID: soloModel}})
	only := scenarioProvider{id: "hot", decodeTPS: 60, totalMemGB: 64, gpuActiveGB: 8}.register(t, solo, soloModel)
	setThermalState(t, only, "serious")

	if got := reserveAndRelease(solo, soloModel, 0); got != "hot" {
		t.Fatalf("sole serious provider returned %q, want hot: serious is a cost "+
			"penalty, not an eligibility gate", got)
	}
}

// `critical` is the only thermal state that gates. It is excluded even when it
// is the entire fleet, so the request sheds rather than cooking the machine.
func TestThermalCriticalIsExcludedFromRouting(t *testing.T) {
	reg := New(testLogger())
	model := "thermal-critical-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	scenarioProvider{id: "cool", decodeTPS: 30, totalMemGB: 64, gpuActiveGB: 8}.register(t, reg, model)
	// Deliberately the faster box, so only the thermal gate can exclude it.
	critical := scenarioProvider{id: "critical", decodeTPS: 200, totalMemGB: 128, gpuActiveGB: 8}.register(t, reg, model)
	setThermalState(t, critical, "critical")

	for i := range 25 {
		if got := reserveAndRelease(reg, model, i); got != "cool" {
			t.Fatalf("trial %d selected %q, want cool: critical must never be routed to", i, got)
		}
	}

	solo := New(testLogger())
	soloModel := "thermal-critical-solo"
	solo.SetModelCatalog([]CatalogEntry{{ID: soloModel}})
	only := scenarioProvider{id: "critical", decodeTPS: 200, totalMemGB: 128, gpuActiveGB: 8}.register(t, solo, soloModel)
	setThermalState(t, only, "critical")

	if got := reserveAndRelease(solo, soloModel, 0); got != "" {
		t.Fatalf("sole critical provider returned %q, want no selection", got)
	}
}

// The health term is additive milliseconds, not a multiplier. Pin the exact
// per-state contribution the operator dashboard and routing docs quote.
func TestThermalHealthPenaltyIsAdditiveMilliseconds(t *testing.T) {
	for _, tc := range []struct {
		state string
		want  float64
	}{
		{"nominal", 0},
		{"fair", thermalPenaltyFairMs},
		{"serious", thermalPenaltySeriousMs},
		// critical is gated upstream, so it carries no cost of its own.
		{"critical", 0},
		{"", 0},
	} {
		got := healthPenaltyMs(protocol.SystemMetrics{ThermalState: tc.state}, 0, 0)
		if got != tc.want {
			t.Errorf("healthPenaltyMs(%q) = %.0f, want %.0f", tc.state, got, tc.want)
		}
	}

	// Memory pressure and CPU are fractional scalars over their own budgets and
	// compose additively with thermal — no multiplicative interaction.
	both := healthPenaltyMs(protocol.SystemMetrics{
		MemoryPressure: 0.5,
		CPUUsage:       0.5,
		ThermalState:   "fair",
	}, 0, 0)
	want := 0.5*memoryPressurePenaltyMs + 0.5*cpuUsagePenaltyMs + thermalPenaltyFairMs
	if both != want {
		t.Errorf("combined health penalty = %.0f, want %.0f", both, want)
	}
}
