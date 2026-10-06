package registry_test

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

func TestOffloadedWeightsRequireExplicitValidPayloadDeclaration(t *testing.T) {
	info := protocol.ModelInfo{ID: "qwen", ModelType: "qwen4_exp", SizeBytes: 106294664646,
		EstimatedMemoryGB: 83.03058636859059, SSDOffloadedWeightBytes: 32000153600}
	read := func(value protocol.ModelInfo) float64 {
		return memorypolicy.NativeLoadGB([]protocol.ModelInfo{value}, "qwen")
	}
	if got := read(info); math.Abs(got-info.EstimatedMemoryGB) > 1e-9 {
		t.Fatalf("validated footprint=%v", got)
	}
	for _, modelType := range []string{"", "qwen3_5", "nemotron_h", "custom_qwen4_exp"} {
		unrelated := info
		unrelated.ModelType = modelType
		if read(unrelated) != 0 {
			t.Fatalf("unqualified model type accepted: %q", modelType)
		}
	}
	for _, modelType := range []string{"qwen4_exp_text", " QWEN4_EXP "} {
		native := info
		native.ModelType = modelType
		if read(native) == 0 {
			t.Fatalf("native model type rejected: %q", modelType)
		}
	}
	unrelated := info
	unrelated.ID = "qwen-copy"
	if read(unrelated) != 0 {
		t.Fatal("offload declaration crossed model identity")
	}
	legacy := info
	legacy.SSDOffloadedWeightBytes = 0
	if read(legacy) != 0 {
		t.Fatal("legacy estimates must not retune existing models")
	}
	for _, bytes := range []int64{-1, info.SizeBytes, info.SizeBytes + 1} {
		invalid := info
		invalid.SSDOffloadedWeightBytes = bytes
		if read(invalid) != 0 {
			t.Fatalf("invalid offload bytes accepted: %d", bytes)
		}
	}
	for _, estimate := range []float64{0, -1, math.NaN(), math.Inf(1)} {
		invalid := info
		invalid.EstimatedMemoryGB = estimate
		if read(invalid) != 0 {
			t.Fatalf("invalid estimate accepted: %v", estimate)
		}
	}
	understated := info
	understated.EstimatedMemoryGB = 1
	if got := read(understated); got < info.EstimatedMemoryGB-1e-9 {
		t.Fatalf("estimate undercut padded remaining bytes: %v", got)
	}
}

func TestOffloadedColdAdmissionPreservesKnownFullAndLegacyPolicy(t *testing.T) {
	free := 90.0
	if ok, reported := admission.ReportedLoadAdmits(106.294664646, 0, free, true); ok || !reported {
		t.Fatal("legacy padded disk estimate should not fit")
	}
	if ok, reported := admission.ReportedLoadAdmits(106.294664646, 83.03058636859059, free, true); !ok || !reported {
		t.Fatal("validated offloaded compute should fit")
	}
	for _, value := range []float64{0, -1, math.NaN(), math.Inf(1)} {
		if ok, reported := admission.ReportedLoadAdmits(106.3, 83.03, value, true); ok || !reported {
			t.Fatalf("invalid/empty free memory admitted: %v", value)
		}
	}
	if ok, reported := admission.ReportedLoadAdmits(106.3, 83.03, 0, false); ok || reported {
		t.Fatal("missing provider report must remain legacy/unknown")
	}
	snap := memorypolicy.Input{TotalMemoryGB: 128, ModelSizeGB: 106.294664646,
		EstimatedOffloadedMemoryGB: 83.03058636859059, FreeForLoadGB: &free,
		AvailableOnDisk: true}
	budget, known := memorypolicy.StructuralBudget(&snap)
	if !known || budget <= 0 {
		t.Fatalf("no post-load budget: %d %v", budget, known)
	}
	if fits, known := memorypolicy.BudgetFits(&snap, 5000, 256); !fits || !known {
		t.Fatal("small cold request should fit the offloaded budget")
	}
	snap.ModelLoaded = true
	snap.ActiveTokenBudgetMax = 1000
	snap.ActiveTokenBudgetUsed = 1000
	if memorypolicy.Admits(&snap, 1, 1) {
		t.Fatal("offload estimate bypassed loaded slot's full budget")
	}
	if got, known := memorypolicy.StructuralBudget(&snap); !known || got != 1000 {
		t.Fatalf("live slot budget lost precedence: %d %v", got, known)
	}
}

func TestNativeLoadAllowanceRequiresExplicitValidDeclaration(t *testing.T) {
	info := protocol.ModelInfo{ID: "qwen", ModelType: "qwen4_exp", SizeBytes: 100 << 30,
		SSDOffloadedWeightBytes: 30 << 30, EstimatedMemoryGB: 76, NativeLoadTransientBytes: 6 << 30}
	read := func(value protocol.ModelInfo) float64 {
		return memorypolicy.NativeLoadGB([]protocol.ModelInfo{value}, "qwen")
	}
	if got := read(info); got != 76 {
		t.Fatalf("native load allowance lost: %v", got)
	}
	understated := info
	understated.EstimatedMemoryGB = 1
	if got := read(understated); got != 76 {
		t.Fatalf("understated native estimate accepted: %v", got)
	}
	for _, invalid := range []int64{0, -1, 1<<30 - 1, math.MaxInt64} {
		legacy := info
		legacy.NativeLoadTransientBytes = invalid
		if got := read(legacy); got != 84 {
			t.Fatalf("invalid allowance %d bypassed fallback: %v", invalid, got)
		}
	}
	other := info
	other.ModelType = "nemotron_h"
	if read(other) != 0 {
		t.Fatal("native allowance changed another family")
	}
}

func TestFlash096ColdBudgetFitsReported32810TokensWithoutOverridingWarmCeiling(t *testing.T) {
	// Exact immutable-weight declaration observed on the 128 GiB Flash host.
	info := protocol.ModelInfo{ID: "qwen3.8-flash-next", ModelType: "qwen4_exp",
		SizeBytes: 106294664646, SSDOffloadedWeightBytes: 32000153600,
		EstimatedMemoryGB: 75.02614405564964, NativeLoadTransientBytes: 6264197720}
	p := &production.Provider{Version: "0.9.6", Models: []protocol.ModelInfo{info}}
	snap := memorypolicy.Input{Model: info.ID, TotalMemoryGB: 128,
		ModelSizeGB: 106.294664646, AvailableOnDisk: true}
	if fits, known := memorypolicy.BudgetFits(&snap, 42, 32768); fits || !known {
		t.Fatal("the legacy full-disk estimate should reproduce the cold-capacity rejection")
	}
	snap.EstimatedOffloadedMemoryGB = memorypolicy.NativeLoadGB(p.Models, info.ID)
	if fits, known := memorypolicy.BudgetFits(&snap, 42, 32768); !fits || !known {
		t.Fatal("validated native offload should admit the reported 32,810-token request")
	}
	snap.ModelLoaded = true
	snap.ActiveTokenBudgetMax = 32000
	if fits, known := memorypolicy.BudgetFits(&snap, 42, 32768); fits || !known {
		t.Fatal("a real warm slot ceiling must still override the optimistic cold estimate")
	}
}

func TestModelsUpdateRetainsOffloadDeclaration(t *testing.T) {
	reg := production.New(testLogger())
	reg.SetModelCatalog([]production.CatalogEntry{{ID: "qwen"}})
	p := modelIndexRegister(t, reg, "provider", "qwen")
	merged, _ := reg.MergeProviderModels("provider", []protocol.ModelInfo{{ID: "qwen", ModelType: "qwen4_exp", SizeBytes: 100 << 30,
		EstimatedMemoryGB: 84, SSDOffloadedWeightBytes: 30 << 30}})
	if len(merged) != 1 {
		t.Fatal("model did not merge")
	}
	p.Mu().Lock()
	got := memorypolicy.NativeLoadGB(p.Models, "qwen")
	p.Mu().Unlock()
	if got != 84 {
		t.Fatalf("offload declaration lost in merge: %v", got)
	}
}

func TestOffloadedWeightsDoNotReplaceCatalogHardwareQualification(t *testing.T) {
	// Live load estimates and the catalog's hardware-tier contract are independent.
	free := 90.0
	if admits, known := admission.ReportedLoadAdmits(104.649840190, 81.192351792, free, true); !known || !admits {
		t.Fatal("valid live offloaded load estimate should fit this synthetic headroom")
	}
	if admission.ModelFitsHardware(0, 104.649840190, 128) {
		t.Fatal("unknown catalog requirement must keep the conservative static gate")
	}
	if admission.ModelFitsHardware(256, 104.649840190, 128) {
		t.Fatal("explicit catalog hardware requirement must not be bypassed")
	}
	if !admission.ModelFitsHardware(128, 104.649840190, 128) {
		t.Fatal("an independently approved catalog requirement should remain authoritative")
	}
}

func TestRoutingSnapshotPreservesOffloadAndClearsDifferentModel(t *testing.T) {
	reg := production.New(testLogger())
	reg.SetModelCatalog([]production.CatalogEntry{{ID: "qwen"}, {ID: "other"}})
	p := modelIndexRegister(t, reg, "provider", "qwen")
	reg.MergeProviderModels("provider", []protocol.ModelInfo{{ID: "qwen", ModelType: "qwen4_exp",
		SizeBytes: 100 << 30, EstimatedMemoryGB: 84, SSDOffloadedWeightBytes: 30 << 30}})
	p.Mu().Lock()
	defer p.Mu().Unlock()
	// Both catalog entries are unsized, so both fit sizes remain zero. Reuse
	// the actual quote initializer consumed by routing/capacity projection.
	var snap memorypolicy.Footprint
	snap.Resolve(p.Models, "qwen", 0, float64(p.Hardware.MemoryGB), p.BackendCapacity)
	if snap.EstimatedOffloadedMemoryGB != 84 {
		t.Fatalf("shared routing/capacity projection lost offload footprint: %v", snap.EstimatedOffloadedMemoryGB)
	}
	snap.Resolve(p.Models, "other", 0, float64(p.Hardware.MemoryGB), p.BackendCapacity)
	if snap.EstimatedOffloadedMemoryGB != 0 {
		t.Fatal("shared projection retained another model's offload footprint")
	}
}

func mimoLoadInfo() protocol.ModelInfo {
	return protocol.ModelInfo{
		ID: "test-mimo-native-load", ModelType: "mimo_v2", SizeBytes: 172847269645,
		EstimatedMemoryGB:        float64(189354468528) / float64(uint64(1)<<30),
		NativeLoadTransientBytes: 16507198883,
		WeightHash:               "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}
}

func TestMiMoFullLoadDeclarationAndCatalogUnitsAreChecked(t *testing.T) {
	info := mimoLoadInfo()
	catalogGB := float64(info.SizeBytes) / 1e9 // decimal stored bytes, NOT GiB/padded/min-RAM
	read := func(v protocol.ModelInfo, catalog ...float64) float64 {
		return memorypolicy.NativeLoadGB([]protocol.ModelInfo{v}, info.ID, catalog...)
	}
	want := float64(info.SizeBytes+info.NativeLoadTransientBytes) / float64(uint64(1)<<30)
	if got := read(info, catalogGB); got != want || math.Abs(got+6.5-182.85009114444256) > 1e-9 {
		t.Fatalf("full LOAD/headroom mismatch: %v", got)
	}
	largerCatalog := catalogGB + 2 // 2 decimal GB, not 2 GiB
	wantLarger := want + 2e9/float64(uint64(1)<<30)
	if got := read(info, largerCatalog); math.Abs(got-wantLarger) > 1e-9 {
		t.Fatalf("catalog floor/supplement counted incorrectly: %v want %v", got, wantLarger)
	}
	// Preserve the 16,317,574 metadata bytes omitted by scanner SizeBytes.
	manifestGB := float64(172863587219) / 1e9
	if got := read(info, manifestGB); math.Abs(got+6.5-182.86528806947172) > 1e-9 {
		t.Fatalf("published raw-byte floor drifted: %v", got)
	}
	for _, c := range []float64{0, -1, math.NaN(), math.Inf(1), math.MaxFloat64} {
		if got := read(info, c); got != 0 {
			t.Fatalf("invalid catalog %v accepted: %v", c, got)
		}
	}
	if read(info) != 0 || read(info, catalogGB, catalogGB) != 0 {
		t.Fatal("missing/ambiguous catalog admitted")
	}
	for _, mutate := range []func(*protocol.ModelInfo){
		func(v *protocol.ModelInfo) { v.ID = "foreign" },
		func(v *protocol.ModelInfo) { v.ModelType = "MIMO_V2" },
		func(v *protocol.ModelInfo) { v.ModelType = " mimo_v2 " },
		func(v *protocol.ModelInfo) { v.ModelType = "mimo_v2_nextn" },
		func(v *protocol.ModelInfo) { v.ModelType = "llama" },
		func(v *protocol.ModelInfo) { v.SSDOffloadedWeightBytes = 1 },
		func(v *protocol.ModelInfo) { v.SSDOffloadedWeightBytes = -1 },
		func(v *protocol.ModelInfo) { v.SizeBytes = 0 },
		func(v *protocol.ModelInfo) { v.SizeBytes = -1 },
		func(v *protocol.ModelInfo) { v.SizeBytes = math.MaxInt64 },
		func(v *protocol.ModelInfo) { v.NativeLoadTransientBytes = 0 },
		func(v *protocol.ModelInfo) { v.NativeLoadTransientBytes = 1<<30 - 1 },
		func(v *protocol.ModelInfo) { v.NativeLoadTransientBytes = math.MaxInt64 },
		func(v *protocol.ModelInfo) { v.EstimatedMemoryGB = want - 1 },
		func(v *protocol.ModelInfo) { v.EstimatedMemoryGB = math.NaN() },
		func(v *protocol.ModelInfo) { v.EstimatedMemoryGB = math.Inf(1) },
	} {
		bad := info
		mutate(&bad)
		if got := read(bad, catalogGB); got != 0 {
			t.Fatalf("malformed declaration accepted: %+v => %v", bad, got)
		}
	}
	free := 183.0 - 6.5 // heartbeat is NET of activation + minimum KV already
	if ok, known := admission.ReportedLoadAdmits(catalogGB, read(info, catalogGB), free, true); !known || !ok {
		t.Fatal("validated full LOAD should fit the 183 GiB usable boundary")
	}
	if ok, known := admission.ReportedLoadAdmits(catalogGB, 0, free, true); !known || ok {
		t.Fatal("old disk×1.2 must reproduce the causal rejection")
	}
	tooLow := 179.0 - 6.5
	if ok, known := admission.ReportedLoadAdmits(catalogGB, read(info, catalogGB), tooLow, true); !known || ok {
		t.Fatal("full LOAD quote bypassed actual insufficient memory")
	}
}

func TestMiMoNativeLoadReachesDirectSwapWarmAndColdSpillWithoutWeakeningGates(t *testing.T) {
	info := mimoLoadInfo()
	catalogGB := float64(info.SizeBytes) / 1e9
	var planner *production.ReservationPlanner
	var loads *production.ModelLoadPlanner
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		},
		ModelLoadPlanning: func(actual *production.ModelLoadPlanner) production.ModelLoadPlanning {
			loads = actual
			return actual
		},
	})
	reg.SetModelCatalog([]production.CatalogEntry{{ID: info.ID, SizeGB: catalogGB, MinRAMGB: 256, WeightHash: info.WeightHash}})
	p := makeWarmPoolColdProvider(t, reg, "mimo-price-provider", info.ID, 80, 256, 0)
	p.Mu().Lock()
	p.Hardware.MemoryGB = 256
	p.Models = []protocol.ModelInfo{info}
	p.Mu().Unlock()
	type decisions struct{ direct, swap, warm, cold bool }
	observe := func() decisions {
		now := time.Now()
		direct := planner.ScanCandidates(info.ID, &production.PendingRequest{
			Model: info.ID, EstimatedPromptTokens: 1, RequestedMaxTokens: 1,
		}, false).CandidateCount != 0
		prepared := loads.Prepare()
		_, warmReason := prepared.ColdCandidate(p.ID, info.ID, now)
		_, swap := prepared.Candidate(p.ID, info.ID, now)
		prepared.Close()
		cold := reg.ColdSpillProviders(info.ID, production.RequestTraits{}, false) != 0
		return decisions{direct, swap, warmReason == warmplan.WarmColdEligible, cold}
	}
	set := func(usable float64, value protocol.ModelInfo) {
		free := usable - 6.5
		p.Mu().Lock()
		p.Models = []protocol.ModelInfo{value}
		p.BackendCapacity.FreeForLoadGB = &free
		p.Mu().Unlock()
	}
	for _, usable := range []float64{179, 182, 183, 190, 199, 200} {
		set(usable, info)
		want := usable >= info.EstimatedMemoryGB+6.5
		if got := observe(); got != (decisions{want, want, want, want}) {
			t.Fatalf("usable=%v decisions=%+v, want all %v", usable, got, want)
		}
		legacy := info
		legacy.NativeLoadTransientBytes = 0
		set(usable, legacy)
		oldFits := usable >= float64(info.SizeBytes)/float64(uint64(1)<<30)*1.2+6.5
		if got := observe(); got != (decisions{oldFits, oldFits, oldFits, oldFits}) {
			t.Fatalf("legacy fallback usable=%v decisions=%+v, want all %v", usable, got, oldFits)
		}
	}
	set(183, info)
	// A larger catalog footprint must affect every cold consumer.
	reg.SetModelCatalog([]production.CatalogEntry{{ID: info.ID, SizeGB: catalogGB + 2, MinRAMGB: 256, WeightHash: info.WeightHash}})
	if got := observe(); got != (decisions{}) {
		t.Fatalf("larger catalog bypassed: %+v", got)
	}
	reg.SetModelCatalog([]production.CatalogEntry{{ID: info.ID, SizeGB: catalogGB, MinRAMGB: 512, WeightHash: info.WeightHash}})
	prepared := loads.Prepare()
	_, swap := prepared.Candidate(p.ID, info.ID, time.Now())
	prepared.Close()
	cold := reg.ColdSpillProviders(info.ID, production.RequestTraits{}, false) != 0
	prepared = loads.Prepare()
	_, warmReason := prepared.ColdCandidate(p.ID, info.ID, time.Now())
	prepared.Close()
	warm := warmReason == warmplan.WarmColdEligible
	if swap || cold || warm {
		t.Fatal("native price waived catalog hardware qualification")
	}
	reg.SetModelCatalog([]production.CatalogEntry{{ID: info.ID, SizeGB: catalogGB, MinRAMGB: 256, WeightHash: info.WeightHash}})
	bad := info
	bad.WeightHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	if merged, _ := reg.MergeProviderModels(p.ID, []protocol.ModelInfo{bad}); len(merged) != 0 {
		t.Fatal("native pricing waived existing catalog hash gate")
	}
}
