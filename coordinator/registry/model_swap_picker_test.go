package registry

// Tests for the model-swap load-target picker (bestModelLoadProviderLocked):
// TriggerModelSwaps selects through the shared warm-pool candidate gate, so a
// busy backend slot, a thermal-critical box, or a pair in dispatch-load
// cooldown is never sent load_model, and among eligible boxes the warm-pool
// score picks deterministically instead of index order.

import (
	"testing"
	"time"
)

const pickerModel = "picker-cold-model"

// pickerFixture returns a registry with the cold model in the catalog, a
// queued request for it and the load sender captured.
func pickerFixture(t *testing.T) (*Registry, *[]modelLoadAction) {
	t.Helper()
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: pickerModel, SizeGB: 15}})
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))
	sent := captureWarmPoolLoads(reg)
	req := &QueuedRequest{RequestID: "q", Model: pickerModel, Pending: &PendingRequest{RequestID: "q", Model: pickerModel}}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatal(err)
	}
	return reg, sent
}

// pickerCold registers an idle cold provider for pickerModel.
func pickerCold(t *testing.T, reg *Registry, id string) *Provider {
	t.Helper()
	return makeWarmPoolColdProvider(t, reg, id, pickerModel, 80, 64, 8)
}

func pickerExpectSent(t *testing.T, sent *[]modelLoadAction, want ...string) {
	t.Helper()
	if len(*sent) != len(want) {
		t.Fatalf("load_model sent to %v, want %v", *sent, want)
	}
	for i, w := range want {
		if (*sent)[i].providerID != w {
			t.Fatalf("load_model[%d] sent to %q, want %q (all: %v)", i, (*sent)[i].providerID, w, *sent)
		}
	}
}

// TestSwapPickerSkipsBusyBackendSlot: a provider whose coordinator pending
// ledger is empty but whose backend reports a running/waiting slot (after a
// reconnect, or owner self-route traffic) is not a load target — the load
// would fail with "active slot cannot be evicted". Before the change it was
// picked.
func TestSwapPickerSkipsBusyBackendSlot(t *testing.T) {
	reg, sent := pickerFixture(t)
	busy := pickerCold(t, reg, "busy")
	busy.mu.Lock()
	busy.BackendCapacity.Slots[0].NumRunning = 1
	busy.mu.Unlock()

	reg.TriggerModelSwaps()
	pickerExpectSent(t, sent)

	idle := pickerCold(t, reg, "idle")
	reg.TriggerModelSwaps()
	pickerExpectSent(t, sent, idle.ID)
}

// TestSwapPickerSkipsThermalCritical: a thermal-critical box is not a load
// target even when idle.
func TestSwapPickerSkipsThermalCritical(t *testing.T) {
	reg, sent := pickerFixture(t)
	hot := pickerCold(t, reg, "hot")
	hot.mu.Lock()
	hot.SystemMetrics.ThermalState = "critical"
	hot.mu.Unlock()

	reg.TriggerModelSwaps()
	pickerExpectSent(t, sent)

	cool := pickerCold(t, reg, "cool")
	reg.TriggerModelSwaps()
	pickerExpectSent(t, sent, cool.ID)
}

// TestSwapPickerSkipsDispatchLoadCooldown: a pair that just failed a dispatch
// with a load error is cooling down and must not be re-targeted by the
// planner; the cooldown is per model, so the same box stays a target for
// another model.
func TestSwapPickerSkipsDispatchLoadCooldown(t *testing.T) {
	reg, sent := pickerFixture(t)
	cooled := pickerCold(t, reg, "cooled")
	if !reg.RecordDispatchLoadFailure(cooled.ID, pickerModel) {
		t.Fatal("dispatch-load failure was not recorded")
	}

	reg.TriggerModelSwaps()
	pickerExpectSent(t, sent)

	fresh := pickerCold(t, reg, "fresh")
	reg.TriggerModelSwaps()
	pickerExpectSent(t, sent, fresh.ID)
}

// TestSwapPickerChoosesBestScoreDeterministically: with several idle eligible
// boxes the picker takes the highest warm-pool score (more free memory here),
// not the first in index order, and does so on every run.
func TestSwapPickerChoosesBestScoreDeterministically(t *testing.T) {
	reg, sent := pickerFixture(t)
	// Registered first (index order) but with the least free memory.
	_ = makeWarmPoolColdProvider(t, reg, "first-tight", pickerModel, 80, 64, 40)
	best := makeWarmPoolColdProvider(t, reg, "second-roomy", pickerModel, 80, 64, 4)
	_ = makeWarmPoolColdProvider(t, reg, "third-mid", pickerModel, 80, 64, 20)

	for run := 0; run < 50; run++ {
		reg.TriggerModelSwaps()
		if len(*sent) != run+1 || (*sent)[run].providerID != best.ID {
			t.Fatalf("run %d: load_model sent to %v, want %q every time", run, *sent, best.ID)
		}
		// Release the reservation so the next run plans again.
		reg.ClearPendingModelLoad(best.ID, pickerModel)
	}
}

// TestSwapPickerParityWithLivenessGate: the exclusions the old picker
// enforced through providerLivenessGateLocked still hold through the warm-pool
// gate — private-only, untrusted/offline, stale-challenge and unverified
// boxes are never load targets.
func TestSwapPickerParityWithLivenessGate(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(p *Provider)
	}{
		{"private_only", func(p *Provider) { p.PrivateOnly = true }},
		{"untrusted", func(p *Provider) { p.Status = StatusUntrusted }},
		{"offline", func(p *Provider) { p.Status = StatusOffline }},
		{"stale_challenge", func(p *Provider) { p.LastChallengeVerified = time.Now().Add(-2 * challengeFreshnessMaxAge) }},
		{"runtime_unverified", func(p *Provider) { p.RuntimeVerified = false }},
		{"trust_below_floor", func(p *Provider) { p.TrustLevel = TrustNone }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg, sent := pickerFixture(t)
			excluded := pickerCold(t, reg, "excluded")
			excluded.mu.Lock()
			tc.mutate(excluded)
			excluded.mu.Unlock()
			reg.TriggerModelSwaps()
			pickerExpectSent(t, sent)
		})
	}
}

// TestSwapPickerFitGateUsesReportedTotalMemory pins the fit-gate memory
// source: the warm-pool gate (and now the swap picker) trusts the provider's
// live BackendCapacity.TotalMemoryGB when reported over the registration-time
// Hardware.MemoryGB, and falls back to Hardware.MemoryGB for a legacy
// provider without a capacity report.
func TestSwapPickerFitGateUsesReportedTotalMemory(t *testing.T) {
	reg, sent := pickerFixture(t)
	reg.SetModelCatalog([]CatalogEntry{{ID: pickerModel, SizeGB: 60}})
	p := pickerCold(t, reg, "box")
	p.mu.Lock()
	p.Hardware.MemoryGB = 32 // registration-time figure would reject a 60 GB model
	p.BackendCapacity.TotalMemoryGB = 128
	p.mu.Unlock()
	reg.TriggerModelSwaps()
	pickerExpectSent(t, sent, p.ID)

	reg.ClearPendingModelLoad(p.ID, pickerModel)
	p.mu.Lock()
	p.BackendCapacity = nil // legacy: static hardware gate
	p.mu.Unlock()
	reg.TriggerModelSwaps()
	pickerExpectSent(t, sent, p.ID) // no new send: 60 GB does not fit 32 GB
}

// TestSwapPickerOnePerModelPerPass: one load per queued model per pass, and a
// provider already selected for one model is not reused for another.
func TestSwapPickerOnePerModelPerPass(t *testing.T) {
	reg := New(testLogger())
	const other = "picker-other-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: pickerModel, SizeGB: 15}, {ID: other, SizeGB: 15}})
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))
	sent := captureWarmPoolLoads(reg)
	for _, m := range []string{pickerModel, other} {
		req := &QueuedRequest{RequestID: "q-" + m, Model: m, Pending: &PendingRequest{RequestID: "q-" + m, Model: m}}
		if err := reg.Queue().Enqueue(req); err != nil {
			t.Fatal(err)
		}
	}
	both := pickerCold(t, reg, "both")
	addAdvertisedModel(both, other)
	only := makeWarmPoolColdProvider(t, reg, "only-other", other, 80, 64, 8)
	_ = only

	reg.TriggerModelSwaps()
	if len(*sent) != 2 {
		t.Fatalf("sent %v, want one load per queued model", *sent)
	}
	seen := map[string]int{}
	for _, a := range *sent {
		seen[a.providerID]++
	}
	for id, n := range seen {
		if n != 1 {
			t.Fatalf("provider %s received %d loads in one pass (%v), want at most 1", id, n, *sent)
		}
	}
}
