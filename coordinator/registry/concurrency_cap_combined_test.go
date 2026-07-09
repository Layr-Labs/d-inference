package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Tests for the combined (box-wide) admission cap: per-model quality caps are
// checked independently, so a box saturated on model A still admits model B.
// Behind EIGENINFERENCE_COMBINED_ADMISSION_CAP the admission check also
// requires Σ_slots(load/qc) + 1/qc_candidate <= overcommit.

// TestCombinedAdmissionAdmitsTable pins the pure budget math, including the
// fail-open rules (unresolvable candidate or slot qc) and the epsilon at exact
// budget equality.
func TestCombinedAdmissionAdmitsTable(t *testing.T) {
	cases := []struct {
		name        string
		slots       []combinedSlotLoad
		candidateQC int
		overcommit  float64
		want        bool
	}{
		{name: "empty_box_admits", slots: nil, candidateQC: 10, overcommit: 1.2, want: true},
		{name: "a_at_qc_blocks_b", slots: []combinedSlotLoad{{load: 2, qc: 2}}, candidateQC: 10, overcommit: 1.0, want: false},
		{name: "a_drained_admits_b", slots: []combinedSlotLoad{{load: 0, qc: 2}}, candidateQC: 10, overcommit: 1.0, want: true},
		{name: "overcommit_grants_headroom", slots: []combinedSlotLoad{{load: 2, qc: 2}}, candidateQC: 10, overcommit: 1.2, want: true},
		{name: "slow_candidate_blocked_within_overcommit", slots: []combinedSlotLoad{{load: 2, qc: 2}}, candidateQC: 2, overcommit: 1.2, want: false},
		{name: "exact_budget_equality_admits", slots: []combinedSlotLoad{{load: 2, qc: 2}}, candidateQC: 5, overcommit: 1.2, want: true},
		{name: "unresolvable_slot_skipped", slots: []combinedSlotLoad{{load: 50, qc: 0}}, candidateQC: 4, overcommit: 1.0, want: true},
		{name: "unresolvable_candidate_fails_open", slots: []combinedSlotLoad{{load: 50, qc: 1}}, candidateQC: 0, overcommit: 1.0, want: true},
		{name: "negative_load_ignored", slots: []combinedSlotLoad{{load: -3, qc: 1}}, candidateQC: 4, overcommit: 1.0, want: true},
		{name: "multi_slot_sum", slots: []combinedSlotLoad{{load: 1, qc: 2}, {load: 5, qc: 10}}, candidateQC: 10, overcommit: 1.0, want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := combinedAdmissionAdmits(tc.slots, tc.candidateQC, tc.overcommit); got != tc.want {
				t.Fatalf("combinedAdmissionAdmits(%+v, qc %d, oc %.2f) = %v, want %v",
					tc.slots, tc.candidateQC, tc.overcommit, got, tc.want)
			}
		})
	}
}

// combinedHeadroom evaluates the full admission headroom check (per-model caps
// + combined cap) under the routing path's lock discipline. The production
// entry point resolves the candidate's per-model static rate internally.
func combinedHeadroom(reg *Registry, p *Provider, model string) bool {
	reg.mu.RLock()
	defer reg.mu.RUnlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	return reg.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model)
}

// makeCombinedCapBox builds one provider serving two models: slot A
// (MaxConcurrency 2 — its quality cap) carrying loadA in-flight requests, and
// slot B (MaxConcurrency 24) idle. DecodeTPS 57 -> quality batch
// floor((57/15-1)/0.27) = 10, so qc_A = min(10, 2) = 2 and qc_B = min(10, 24)
// = 10 (per-slot MaxConcurrency clamps qualityConcurrency).
func makeCombinedCapBox(t *testing.T, reg *Registry, modelA, modelB string, loadA int) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, "combined-box", modelA, 57)
	p.mu.Lock()
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
		{Model: modelA, State: "running", MaxConcurrency: 2, NumRunning: loadA},
		{Model: modelB, State: "running", MaxConcurrency: 24},
	}
	p.mu.Unlock()
	return p
}

// TestCombinedAdmissionCapCrossModel is the cross-model hard edge end to end
// through hasConcurrencyHeadroomForModelCapResolvedLocked: with the flag OFF a box
// saturated on model A still admits model B (today's behavior, byte-identical);
// with the flag ON the A-saturated box refuses B (Σ 2/2 + 1/10 = 1.1 > 1.0);
// once A drains, B admits again (0 + 1/10 <= 1.0).
func TestCombinedAdmissionCapCrossModel(t *testing.T) {
	modelA := "combined-model-a"
	modelB := "combined-model-b"

	// Flag OFF (default): A-saturated box still admits B — the pre-existing
	// independent per-model behavior this flag must not change while dormant.
	reg := New(testLogger())
	enableQualityCap(t, reg, "1.0")
	p := makeCombinedCapBox(t, reg, modelA, modelB, 2)
	if !combinedHeadroom(reg, p, modelB) {
		t.Fatal("flag off: A-saturated box must still admit B (independent per-model caps)")
	}

	// Flag ON: the same box refuses B while A sits at its quality cap.
	reg = New(testLogger())
	enableQualityCap(t, reg, "1.0")
	reg.SetCombinedAdmissionCap(true)
	p = makeCombinedCapBox(t, reg, modelA, modelB, 2)
	if combinedHeadroom(reg, p, modelB) {
		t.Fatal("flag on: A at its quality cap must make B inadmissible (box-wide budget)")
	}
	// A's own per-model cap still binds first for A itself (load 2 >= cap 2).
	if combinedHeadroom(reg, p, modelA) {
		t.Fatal("flag on: A at its quality cap must stay inadmissible for A")
	}

	// A drains -> B admits (same registry/flag state).
	p.mu.Lock()
	p.BackendCapacity.Slots[0].NumRunning = 0
	p.mu.Unlock()
	if !combinedHeadroom(reg, p, modelB) {
		t.Fatal("flag on: B must admit once A drains")
	}
}

// TestCombinedAdmissionUsesPerModelRateForResidentSlots pins the #524 merge
// boundary: co-resident slot load must be normalized by THAT model's resolved
// solo rate, not the provider-wide registration benchmark. A slow model at one
// request already consumes its whole quality budget even when the box happened
// to benchmark fast on another model. Trusted per-model seeds must also bind on
// providers that did not report a registration benchmark.
func TestCombinedAdmissionUsesPerModelRateForResidentSlots(t *testing.T) {
	modelA := "combined-slow-resident"
	modelB := "combined-slow-candidate"

	for _, providerTPS := range []float64{93, 0} {
		t.Run(fmt.Sprintf("provider_tps_%.0f", providerTPS), func(t *testing.T) {
			reg := New(testLogger())
			enablePerModelQualityCap(t, reg, modelA+"=14,"+modelB+"=14", "", "")
			reg.SetCombinedAdmissionCap(true)
			p := makeCombinedCapBox(t, reg, modelA, modelB, 1)
			p.mu.Lock()
			p.DecodeTPS = providerTPS
			p.BackendCapacity.Slots[0].MaxConcurrency = 24
			p.BackendCapacity.Slots[1].MaxConcurrency = 24
			p.mu.Unlock()

			if combinedHeadroom(reg, p, modelB) {
				t.Fatal("slow resident at quality concurrency 1 must exhaust the combined box budget")
			}
		})
	}
}

// TestCombinedAdmissionCountsPendingColdModelWithoutHeartbeatSlot covers the
// gap between coordinator reservation and the next provider heartbeat. A cold
// model with a pending request may not have a BackendCapacity slot yet, but its
// load still consumes box-wide quality capacity. The independent per-model cap
// permits the second request (ceil(1 * 1.2) = 2); the combined cap must reject it.
func TestCombinedAdmissionCountsPendingColdModelWithoutHeartbeatSlot(t *testing.T) {
	resident := "combined-resident"
	cold := "combined-pending-cold"
	reg := New(testLogger())
	enablePerModelQualityCap(t, reg, cold+"=14", "", "")
	reg.SetCombinedAdmissionCap(true)
	p := makeSchedulerProvider(t, reg, "pending-cold-box", resident, 93)
	p.mu.Lock()
	p.pendingReqs["cold-1"] = &PendingRequest{RequestID: "cold-1", Model: cold}
	p.mu.Unlock()

	if combinedHeadroom(reg, p, cold) {
		t.Fatal("pending cold model absent from heartbeat slots must consume the combined box budget")
	}
}

// TestCombinedAdmissionCapFailOpenRules pins the wrapper's fail-open guards:
// no benchmark on a non-dedicated candidate (the per-model cap's trust rule),
// quality cap disabled, and a slotless provider all admit.
func TestCombinedAdmissionCapFailOpenRules(t *testing.T) {
	modelA := "combined-failopen-a"
	modelB := "combined-failopen-b"

	// No registration benchmark (DecodeTPS 0) and not dedicated: fail open even
	// with the flag on — mirrors effectiveMaxConcurrencyForModelLocked's rule of
	// never hard-capping a non-dedicated model from the bandwidth fallback.
	reg := New(testLogger())
	enableQualityCap(t, reg, "1.0")
	reg.SetCombinedAdmissionCap(true)
	p := makeCombinedCapBox(t, reg, modelA, modelB, 2)
	p.mu.Lock()
	p.DecodeTPS = 0
	p.Hardware.MemoryBandwidthGBs = 800
	p.mu.Unlock()
	if !combinedHeadroom(reg, p, modelB) {
		t.Fatal("no-benchmark non-dedicated candidate must fail open under the combined cap")
	}

	// Quality cap disabled: the combined budget has no meaningful qc inputs and
	// must stay dormant even with the flag on.
	reg = New(testLogger())
	reg.SetQualityConcurrencyCap(false, 1.0, 15, 4)
	reg.SetCombinedAdmissionCap(true)
	p = makeCombinedCapBox(t, reg, modelA, modelB, 2)
	if !combinedHeadroom(reg, p, modelB) {
		t.Fatal("combined cap must be dormant while the quality cap is disabled")
	}

	// No backend capacity: nothing box-wide to combine.
	reg = New(testLogger())
	enableQualityCap(t, reg, "1.0")
	reg.SetCombinedAdmissionCap(true)
	p = makeSchedulerProvider(t, reg, "slotless", modelB, 57)
	p.mu.Lock()
	p.BackendCapacity = nil
	p.mu.Unlock()
	if !combinedHeadroom(reg, p, modelB) {
		t.Fatal("provider without backend capacity must fail open under the combined cap")
	}
}
