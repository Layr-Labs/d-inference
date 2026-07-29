package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Tests for the paged cold token-budget ceiling (servability.go).
//
// coldTokenBudgetEstimate mirrors the provider's CONTIGUOUS reserve arithmetic
// — 0.9×mem − padded weights − activation reserve — and its own doc argues
// that the estimate converges to the warm report because "both are the same
// subtraction". v0.8.0's paged backend breaks that premise: a paged slot's
// ceiling is a separately planned physical pool bounded by
// min(8 GiB, RAM/16) (PagedKVPhysicalCapacityPolicy), which on a 96 GiB box is
// ~10× smaller than the contiguous grant. These tests pin the second ceiling
// that closes the gap, and — just as importantly — pin the three cases where
// it must NOT fire.

// gemma-4 paged marginal KV rate: 20,480 B/token over the full-attention
// layers. A 96 GiB box plans min(8 GiB, 96/16 = 6 GiB) of pool, so a paged
// slot there tops out near 314k tokens whatever the contiguous subtraction
// says.
const (
	pagedKVRateBytesPerToken = int64(20_480)
	pagedBoxMemoryGB         = 96.0
	pagedBoxModelSizeGB      = 12.0
	pagedProviderVersion     = "0.8.0"
)

// coldPagedSnapshot is a provider whose slot for the model is present in the
// capacity report but NOT resident to snapshotStructuralBudget — the
// wedge-recovery window, where EngineV2Bridge reports state "reloading" with a
// live kvBytesPerToken and a KV byte capacity that has collapsed to zero (so
// activeTokenBudgetMax is 0). This is the one reachable shape that carries a
// real per-token rate without a resident budget; the ordinary 1h idle unload
// leaves slots:[] and therefore no rate at all. See the "Reach" note on
// pagedColdTokenBudgetCeiling.
func coldPagedSnapshot(paged bool) routingSnapshot {
	return routingSnapshot{
		binaryVersion:   pagedProviderVersion,
		slotState:       "reloading",
		modelLoaded:     false,
		availableOnDisk: true,
		totalMemoryGB:   pagedBoxMemoryGB,
		modelSizeGB:     pagedBoxModelSizeGB,
		kvBytesPerToken: pagedKVRateBytesPerToken,
		pagedKVBackend:  paged,
	}
}

// A paged box and a contiguous box of identical hardware, both cold for the
// same model, must get DIFFERENT cold estimates: the contiguous box keeps the
// logical-grant subtraction, the paged box is clamped to its pool ceiling.
func TestColdBudgetEstimateSplitsByKVBackend(t *testing.T) {
	contiguous, known := snapshotStructuralBudget(coldPagedSnapshot(false))
	if !known {
		t.Fatal("contiguous cold estimate must be known")
	}
	wantContiguous := coldTokenBudgetEstimate(
		pagedBoxMemoryGB, pagedBoxModelSizeGB, pagedKVRateBytesPerToken, pagedProviderVersion)
	if contiguous != wantContiguous {
		t.Fatalf("contiguous cold estimate = %d, want the unchanged %d", contiguous, wantContiguous)
	}

	paged, known := snapshotStructuralBudget(coldPagedSnapshot(true))
	if !known {
		t.Fatal("paged cold estimate must be known")
	}
	wantPaged := pagedColdTokenBudgetCeiling(pagedBoxMemoryGB, pagedKVRateBytesPerToken)
	if paged != wantPaged {
		t.Fatalf("paged cold estimate = %d, want the pool ceiling %d", paged, wantPaged)
	}

	// The whole point: the two differ by roughly an order of magnitude, and
	// the paged one is the tighter.
	if paged >= contiguous {
		t.Fatalf("paged estimate %d must be tighter than the contiguous %d", paged, contiguous)
	}
	if contiguous/paged < 5 {
		t.Fatalf("paged clamp barely binds (%d vs %d) — the fixture no longer reproduces the gap", paged, contiguous)
	}
}

// The clamp must never LOOSEN an estimate. When the contiguous subtraction is
// already tighter than the pool ceiling (a small box, or the conservative
// kvCacheBytesPerToken default at work), the existing estimate stands.
func TestColdBudgetEstimateClampNeverLoosens(t *testing.T) {
	// A weight-heavy box: the contiguous subtraction leaves under a GiB while
	// the pool ceiling would allow twice that, so the clamp must not fire.
	t.Run("contiguous grant already tighter than the pool", func(t *testing.T) {
		snap := coldPagedSnapshot(true)
		snap.totalMemoryGB = 32
		snap.modelSizeGB = 20

		contiguousOnly := snap
		contiguousOnly.pagedKVBackend = false

		paged, _ := snapshotStructuralBudget(snap)
		contiguous, _ := snapshotStructuralBudget(contiguousOnly)
		if paged != contiguous {
			t.Fatalf("weight-heavy paged estimate = %d, want the unchanged %d — the clamp may only take the tighter branch",
				paged, contiguous)
		}
		if ceiling := pagedColdTokenBudgetCeiling(32, pagedKVRateBytesPerToken); ceiling <= contiguous {
			t.Fatalf("fixture no longer exercises the non-binding branch: ceiling %d <= estimate %d", ceiling, contiguous)
		}
	})

	// The invariant, swept: for every box size and weight, the paged estimate
	// is at most the contiguous one. This change can only ever tighten.
	t.Run("invariant across the fleet", func(t *testing.T) {
		for _, memGB := range []float64{16, 24, 32, 36, 48, 64, 96, 128, 192, 512} {
			for _, sizeGB := range []float64{4, 12, 20, 40} {
				snap := coldPagedSnapshot(true)
				snap.totalMemoryGB, snap.modelSizeGB = memGB, sizeGB
				contiguousOnly := snap
				contiguousOnly.pagedKVBackend = false

				paged, pagedKnown := snapshotStructuralBudget(snap)
				contiguous, contiguousKnown := snapshotStructuralBudget(contiguousOnly)
				if pagedKnown != contiguousKnown {
					t.Fatalf("mem=%.0f size=%.0f: knownness diverged (%v vs %v)",
						memGB, sizeGB, pagedKnown, contiguousKnown)
				}
				if paged > contiguous {
					t.Fatalf("mem=%.0f size=%.0f: paged estimate %d LOOSER than contiguous %d",
						memGB, sizeGB, paged, contiguous)
				}
			}
		}
	})
}

// Fail-open cases. Each of these must leave the estimate byte-identical to
// today's, because acting on an ambiguous input here can produce a terminal
// prompt_too_long 429.
func TestColdBudgetEstimateClampFailsOpen(t *testing.T) {
	baseline, _ := snapshotStructuralBudget(coldPagedSnapshot(false))

	t.Run("no backend ever observed", func(t *testing.T) {
		// A pre-0.8.0 provider, or a box that has loaded nothing yet.
		// Unobserved is not contiguous, but it is certainly not paged.
		snap := coldPagedSnapshot(false)
		got, known := snapshotStructuralBudget(snap)
		if !known || got != baseline {
			t.Fatalf("unobserved-backend estimate = (%d, %v), want (%d, true)", got, known, baseline)
		}
	})

	t.Run("paged but no reported KV rate", func(t *testing.T) {
		// A truly cold box has no slot for the model and so reports no rate.
		// Dividing the paged byte bound by the generic kvCacheBytesPerToken
		// placeholder (400 kB/token, a contiguous 7B measurement) would be
		// ~20× tighter than the truth, so the clamp must not fire at all.
		snap := coldPagedSnapshot(true)
		snap.kvBytesPerToken = 0
		unratedBaseline := coldTokenBudgetEstimate(
			pagedBoxMemoryGB, pagedBoxModelSizeGB, 0, pagedProviderVersion)
		got, known := snapshotStructuralBudget(snap)
		if !known || got != unratedBaseline {
			t.Fatalf("unrated paged estimate = (%d, %v), want (%d, true)", got, known, unratedBaseline)
		}
	})

	t.Run("resident slot keeps its reported budget", func(t *testing.T) {
		// A warm paged slot reports its REAL ceiling; the estimate is not
		// consulted at all and the clamp must not touch it.
		snap := coldPagedSnapshot(true)
		snap.modelLoaded = true
		snap.slotState = "running"
		snap.activeTokenBudgetMax = 314_572
		got, known := snapshotStructuralBudget(snap)
		if !known || got != 314_572 {
			t.Fatalf("resident paged estimate = (%d, %v), want the reported (314572, true)", got, known)
		}
	})
}

// The mirrored pool arithmetic itself: min(8 GiB, RAM/16) / rate, with both
// branches of the min exercised and every missing input failing open.
func TestPagedColdTokenBudgetCeilingBoundaries(t *testing.T) {
	const gib = float64(int64(1) << 30)

	// RAM/16 binds below 128 GiB.
	if got, want := pagedColdTokenBudgetCeiling(64, 20_480), int64(64*gib/16)/20_480; got != want {
		t.Fatalf("64 GiB ceiling = %d, want %d (RAM/16 branch)", got, want)
	}
	// The 8 GiB absolute cap binds at and above 128 GiB.
	if got, want := pagedColdTokenBudgetCeiling(512, 20_480), int64(8*gib)/20_480; got != want {
		t.Fatalf("512 GiB ceiling = %d, want %d (absolute-cap branch)", got, want)
	}
	// Exactly at the crossover the two branches agree.
	if pagedColdTokenBudgetCeiling(128, 20_480) != pagedColdTokenBudgetCeiling(512, 20_480) {
		t.Fatal("128 GiB is the crossover: RAM/16 and the 8 GiB cap must agree there")
	}
	// Missing inputs fail open.
	for name, got := range map[string]int64{
		"no memory": pagedColdTokenBudgetCeiling(0, 20_480),
		"no rate":   pagedColdTokenBudgetCeiling(96, 0),
		"neg rate":  pagedColdTokenBudgetCeiling(96, -1),
		"rate above the whole pool": pagedColdTokenBudgetCeiling(
			96, int64(7*gib)),
	} {
		if got != 0 {
			t.Fatalf("%s: ceiling = %d, want 0 (do not clamp)", name, got)
		}
	}
}

// runsPagedKVLocked is the one routing reader of the KV-backend record. It
// answers a MACHINE-level question, so any paged slot makes the box paged, and
// both "contiguous" and "never observed" must read false — the reader's
// no-clamp branch is correct for either.
func TestProviderRunsPagedKV(t *testing.T) {
	paged, contiguous := KVBackendPaged, KVBackendContiguous
	for name, tc := range map[string]struct {
		slots     []protocol.BackendSlotCapacity
		wantPaged bool
	}{
		"no slots":              {nil, false},
		"slot names no backend": {[]protocol.BackendSlotCapacity{{Model: "a"}}, false},
		"contiguous only": {[]protocol.BackendSlotCapacity{
			{Model: "a", KVBackend: &contiguous}}, false},
		"paged only": {[]protocol.BackendSlotCapacity{
			{Model: "a", KVBackend: &paged}}, true},
		"mixed box reads paged": {[]protocol.BackendSlotCapacity{
			{Model: "a", KVBackend: &contiguous},
			{Model: "b", KVBackend: &paged}}, true},
	} {
		t.Run(name, func(t *testing.T) {
			p := &Provider{}
			p.mu.Lock()
			p.recordKVBackendsLocked(&protocol.BackendCapacity{Slots: tc.slots})
			gotPaged := p.runsPagedKVLocked()
			p.mu.Unlock()
			if gotPaged != tc.wantPaged {
				t.Fatalf("paged = %v, want %v", gotPaged, tc.wantPaged)
			}
		})
	}
}

// End-to-end through the real registry: two boxes of identical hardware, the
// same model on disk and non-resident on both, differing only in the backend
// their heartbeats name. The paged one must be structurally smaller, and the
// contiguous one must be untouched by this change.
func TestMixedBackendFleetColdEstimates(t *testing.T) {
	const model = "gemma-4-26b-qat-4bit"
	r := New(testLogger())
	r.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: pagedBoxModelSizeGB, MinRAMGB: 24}})

	pagedBox := makeSchedulerProvider(t, r, "paged-96", model, 100)
	contiguousBox := makeSchedulerProvider(t, r, "contiguous-96", model, 100)
	for _, p := range []*Provider{pagedBox, contiguousBox} {
		p.mu.Lock()
		p.Version = pagedProviderVersion
		p.mu.Unlock()
	}
	sendColdBackendHeartbeat(r, pagedBox.ID, model, KVBackendPaged)
	sendColdBackendHeartbeat(r, contiguousBox.ID, model, KVBackendContiguous)

	pagedBudget := coldStructuralBudget(t, r, pagedBox, model)
	contiguousBudget := coldStructuralBudget(t, r, contiguousBox, model)

	wantContiguous := coldTokenBudgetEstimate(
		pagedBoxMemoryGB, pagedBoxModelSizeGB, pagedKVRateBytesPerToken, pagedProviderVersion)
	if contiguousBudget != wantContiguous {
		t.Fatalf("contiguous box budget = %d, want the unchanged cold estimate %d", contiguousBudget, wantContiguous)
	}
	wantPaged := pagedColdTokenBudgetCeiling(pagedBoxMemoryGB, pagedKVRateBytesPerToken)
	if pagedBudget != wantPaged {
		t.Fatalf("paged box budget = %d, want the pool ceiling %d", pagedBudget, wantPaged)
	}

	// The fleet ceiling PredictServable computes is the max across providers,
	// so a mixed fleet is still sized by its contiguous boxes — the clamp
	// tightens per-provider admission without shedding fleet-wide.
	v := r.PredictServable(model, 400_000, 400_000, 256, 0, RequestTraits{}, false)
	if v.FleetMaxBudget != wantContiguous {
		t.Fatalf("FleetMaxBudget = %d, want the contiguous box's %d", v.FleetMaxBudget, wantContiguous)
	}
	if !v.Servable {
		t.Fatalf("mixed fleet must still serve a request the contiguous box can hold: %+v", v)
	}
}

// sendColdBackendHeartbeat delivers a capacity report in which the model's slot
// is present but NOT resident to the structural-budget reader: state
// "reloading" (the wedge-recovery window EngineV2Bridge reports) with a real
// per-token KV cost and a collapsed byte capacity, so activeTokenBudgetMax is
// absent. This is the only shape a live provider emits that reaches the cold
// branch with a usable KV rate — see the "Reach" note on
// pagedColdTokenBudgetCeiling.
func sendColdBackendHeartbeat(r *Registry, providerID, model, backend string) {
	kind := backend
	r.Heartbeat(providerID, &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal",
		},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: pagedBoxMemoryGB,
			Slots: []protocol.BackendSlotCapacity{{
				Model:           model,
				State:           "reloading",
				KVBytesPerToken: pagedKVRateBytesPerToken,
				KVBackend:       &kind,
			}},
		},
	})
}

// coldStructuralBudget reads the provider's structural budget through the real
// routing snapshot, so the test exercises the snapshot wiring rather than a
// hand-built struct.
func coldStructuralBudget(t *testing.T, r *Registry, p *Provider, model string) int64 {
	t.Helper()
	r.mu.RLock()
	snap, ok := r.snapshotProviderLocked(p, model, RequestTraits{}, false)
	r.mu.RUnlock()
	if !ok {
		t.Fatalf("provider %s failed the routing gates", p.ID)
	}
	if snap.modelLoaded {
		t.Fatalf("provider %s must be COLD for %s (slot state %q)", p.ID, model, snap.slotState)
	}
	budget, known := snapshotStructuralBudget(snap)
	if !known {
		t.Fatalf("provider %s structural budget unknown", p.ID)
	}
	return budget
}
