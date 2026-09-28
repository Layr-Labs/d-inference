package registry

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func reviewedProfileFixture(t *testing.T) (*Provider, *servingPerformanceProfile) {
	t.Helper()
	profile := &servingPerformanceProfile{
		ID: "test-only-ultra", ModelID: "model", ArtifactSHA256: strings.Repeat("a", 64),
		ProviderVersion: "test", RuntimeRevision: servingPerformanceRuntimeRevision,
		KVBackend: "paged", ChipName: "Apple M5 Ultra", GPUCores: 80, MemoryGB: 192,
		ContextTokensMax: 32768, MaxConcurrency: 16, WholeMacConcurrency: 16,
		QualificationReportSHA256: strings.Repeat("b", 64),
		BatchCurve: []servingBatchPoint{
			{Width: 1, DecodeP10TPS: 90, AggregateDecodeTPS: 100, PrefillTPS: 6000, FirstContentP95MS: 1200},
			{Width: 16, DecodeP10TPS: 35, AggregateDecodeTPS: 700, PrefillTPS: 6000, FirstContentP95MS: 2800},
		},
	}
	previous := reviewedServingPerformanceProfiles
	reviewedServingPerformanceProfiles = map[string]*servingPerformanceProfile{profile.ID: profile}
	t.Cleanup(func() { reviewedServingPerformanceProfiles = previous })
	backend := "paged"
	p := &Provider{Version: "test", Hardware: protocol.Hardware{ChipName: profile.ChipName, GPUCores: 80, MemoryGB: 192},
		Models: []protocol.ModelInfo{{ID: "model", WeightHash: profile.ArtifactSHA256}},
		BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
			Model: "model", MaxConcurrency: 16, ActiveTokenBudgetMax: 100000,
			KVBackend: &backend, PerformanceProfile: &protocol.ServingPerformanceProfileReference{
				ID: profile.ID, RuntimeRevision: profile.RuntimeRevision, ContextTokens: 32768},
		}}}}
	return p, profile
}

func TestQualifiedPerformanceProfileExactIdentityAndCap(t *testing.T) {
	p, profile := reviewedProfileFixture(t)
	r := &Registry{qualityCapEnabled: true, qualityCapFloorTPS: 30, qualityCapFallback: 1}
	if got := qualifiedPerformanceProfileLocked(p, "model"); got != profile {
		t.Fatal("exact reviewed identity did not resolve")
	}
	if got := r.effectiveMaxConcurrencyForModelRateLocked(p, "model", soloModelTPS{tps: 35, perModel: true}); got != 16 {
		t.Fatalf("qualified curve replaced by legacy M4 model: got %d", got)
	}
	p.BackendCapacity.Slots[0].MaxConcurrency = 2
	if got := r.effectiveMaxConcurrencyForModelRateLocked(p, "model", soloModelTPS{tps: 35, perModel: true}); got != 2 {
		t.Fatalf("operator cap lost: %d", got)
	}
	p.BackendCapacity.Slots[0].PerformanceProfile.ContextTokens++
	if qualifiedPerformanceProfileLocked(p, "model") != nil {
		t.Fatal("profile borrowed beyond context range")
	}
	p.BackendCapacity.Slots[0].PerformanceProfile.ContextTokens--
	p.Models[0].WeightHash = strings.Repeat("c", 64)
	if qualifiedPerformanceProfileLocked(p, "model") != nil {
		t.Fatal("profile borrowed across artifacts")
	}
	p.Models[0].WeightHash = profile.ArtifactSHA256
	p.Hardware.GPUCores = 64
	if qualifiedPerformanceProfileLocked(p, "model") != nil {
		t.Fatal("profile borrowed across GPU bins")
	}
	p.Hardware.GPUCores = 80
	p.Version = "next-release"
	if qualifiedPerformanceProfileLocked(p, "model") != nil {
		t.Fatal("profile borrowed across runtime versions")
	}
}

func TestQualifiedProfilePreservesConfiguredDecodeFloor(t *testing.T) {
	p, profile := reviewedProfileFixture(t)
	profile.BatchCurve = []servingBatchPoint{
		{Width: 1, DecodeP10TPS: 90, AggregateDecodeTPS: 100, PrefillTPS: 6000, FirstContentP95MS: 1200},
		{Width: 4, DecodeP10TPS: 50, AggregateDecodeTPS: 250, PrefillTPS: 5000, FirstContentP95MS: 1500},
		{Width: 8, DecodeP10TPS: 40, AggregateDecodeTPS: 450, PrefillTPS: 4500, FirstContentP95MS: 1800},
		{Width: 16, DecodeP10TPS: 35, AggregateDecodeTPS: 700, PrefillTPS: 4000, FirstContentP95MS: 2800},
	}
	for _, tc := range []struct {
		name           string
		enabled        bool
		floor          float64
		operator, want int
	}{
		{"release floor", true, 30, 16, 16},
		{"raised floor", true, 40, 16, 8},
		{"stricter floor", true, 45, 16, 4},
		{"operator between passing widths", true, 40, 6, 6},
		{"operator between rejected widths", true, 45, 6, 4},
		{"operator below passing point", true, 45, 3, 3},
		{"floor above solo", true, 100, 16, 1},
		{"floor disabled", false, 100, 16, 16},
		{"zero floor", true, 0, 16, 16},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p.BackendCapacity.Slots[0].MaxConcurrency = tc.operator
			r := New(testLogger())
			r.qualityCapEnabled, r.qualityCapFloorTPS, r.qualityCapFallback = tc.enabled, tc.floor, 1
			if got := r.effectiveMaxConcurrencyForModelRateLocked(p, "model", soloModelTPS{tps: 1000}); got != tc.want {
				t.Fatalf("admission cap = %d, want %d", got, tc.want)
			}
			warmFloor := tc.floor
			if !tc.enabled {
				warmFloor = 0
			}
			quality, aggregate, prefill := r.warmPoolCapacityLocked(p, "model", warmTargetParams{DecodeFloorTPS: warmFloor})
			point, _ := profile.batchAt(tc.want)
			wantAggregate := point.AggregateDecodeTPS
			if point.Width != tc.want {
				wantAggregate = point.DecodeP10TPS * float64(tc.want)
			}
			if quality != tc.want || aggregate != wantAggregate || prefill != point.PrefillTPS {
				t.Fatalf("warm capacity = %d/%v/%v, want %d/%v/%v", quality, aggregate, prefill, tc.want, wantAggregate, point.PrefillTPS)
			}
		})
	}
}

func TestQualifiedCurveDoesNotExtrapolate(t *testing.T) {
	_, profile := reviewedProfileFixture(t)
	snapshot := routingSnapshot{performanceProfile: profile, backendRunning: 7, observedDecodeTPS: 1000, decodeTPS: 1000}
	if got := projectedPerRequestDecodeTPSAtBatch(&snapshot, 7); got != 35 {
		t.Fatalf("used synthetic curve instead of measured conservative point: %v", got)
	}
	if _, ok := profile.batchAt(17); ok {
		t.Fatal("extrapolated beyond measured width")
	}
	profile.BatchCurve[1].DecodeP10TPS = 29
	if profile.valid() {
		t.Fatal("accepted sub-floor release curve")
	}
}

func TestWholeMacServiceReconcilesFreshReservations(t *testing.T) {
	p, _ := reviewedProfileFixture(t)
	now := time.Now()
	p.CapacityAcceptedAt = now
	used := 14.0 / 16
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.pendingReqs = map[string]*PendingRequest{
		"overlap": {Model: "model", reservedAt: now.Add(-time.Second)},
		"fresh":   {Model: "model", reservedAt: now.Add(time.Second)},
	}
	overlapID := "6e1f61d1-e22c-4d24-a3a7-d347772a48cb"
	p.pendingReqs["overlap"].serviceReservationID.Store(&serviceReservationIdentity{wire: overlapID})
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{
		ID: overlapID, UsedFraction: 1.0 / 16,
	}}
	if !p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("last whole-Mac slot unavailable")
	}
	p.pendingReqs["another"] = &PendingRequest{Model: "model", reservedAt: now.Add(time.Second)}
	if p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("fresh work double-spent reported allowance")
	}
	delete(p.pendingReqs, "another")
	if !p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("retired reservation did not release headroom")
	}
	used = 1
	if p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("other-model allowance ignored")
	}
}

func TestWholeMacServiceChargeSurvivesProfileWithdrawal(t *testing.T) {
	p, _ := reviewedProfileFixture(t)
	p.pendingReqs = make(map[string]*PendingRequest)
	p.CapacityAcceptedAt = time.Now().Add(-time.Second)
	used := 14.0 / 16
	p.BackendCapacity.WholeMacServiceUsed = &used
	p.addPendingLocked(&PendingRequest{RequestID: "one", Model: "model"})
	p.addPendingLocked(&PendingRequest{RequestID: "two", Model: "model"})
	p.BackendCapacity.Slots[0].PerformanceProfile = nil
	if p.hasWholeMacServiceHeadroomLocked("model") {
		t.Fatal("withdrawing the profile discounted outstanding reservation charges")
	}
}

func TestPerformanceProfileCapacityClonesDoNotAliasLiveAdmission(t *testing.T) {
	p, _ := reviewedProfileFixture(t)
	used := 0.5
	p.BackendCapacity.WholeMacServiceUsed = &used
	var capacity protocol.BackendCapacity
	cloneBackendCapacityFields(&capacity, p.BackendCapacity)
	var slot protocol.BackendSlotCapacity
	cloneBackendSlot(&slot, &p.BackendCapacity.Slots[0])
	*capacity.WholeMacServiceUsed = 0
	slot.PerformanceProfile.ContextTokens = 1
	if *p.BackendCapacity.WholeMacServiceUsed != 0.5 {
		t.Fatal("snapshot changed live service allowance")
	}
	if p.BackendCapacity.Slots[0].PerformanceProfile.ContextTokens != 32768 {
		t.Fatal("snapshot changed live profile identity")
	}
}
