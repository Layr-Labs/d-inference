package registry

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestOffloadedWeightsRequireExplicitValidPayloadDeclaration(t *testing.T) {
	info := protocol.ModelInfo{ID: "qwen", ModelType: "qwen4_exp", SizeBytes: 106294664646,
		EstimatedMemoryGB: 83.03058636859059, SSDOffloadedWeightBytes: 32000153600}
	read := func(value protocol.ModelInfo) float64 {
		return advertisedOffloadedMemoryGBLocked(&Provider{Models: []protocol.ModelInfo{value}}, "qwen")
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
	if ok, reported := reportedFreeForLoadAdmits(106.294664646, &free); ok || !reported {
		t.Fatal("legacy padded disk estimate should not fit")
	}
	if ok, reported := reportedFreeForLoadAdmitsWithOffload(106.294664646, 83.03058636859059, &free); !ok || !reported {
		t.Fatal("validated offloaded compute should fit")
	}
	for _, value := range []float64{0, -1, math.NaN(), math.Inf(1)} {
		if ok, reported := reportedFreeForLoadAdmitsWithOffload(106.3, 83.03, &value); ok || !reported {
			t.Fatalf("invalid/empty free memory admitted: %v", value)
		}
	}
	if ok, reported := reportedFreeForLoadAdmitsWithOffload(106.3, 83.03, nil); ok || reported {
		t.Fatal("missing provider report must remain legacy/unknown")
	}
	snap := routingSnapshot{totalMemoryGB: 128, modelSizeGB: 106.294664646,
		estimatedOffloadedMemoryGB: 83.03058636859059, freeForLoadGB: &free,
		availableOnDisk: true, binaryVersion: "0.9.0"}
	budget, known := snapshotStructuralBudget(&snap)
	if !known || budget <= 0 {
		t.Fatalf("no post-load budget: %d %v", budget, known)
	}
	if fits, known := providerBudgetFits(&snap, 5000, 256); !fits || !known {
		t.Fatal("small cold request should fit the offloaded budget")
	}
	snap.modelLoaded = true
	snap.activeTokenBudgetMax = 1000
	snap.activeTokenBudgetUsed = 1000
	if freeMemoryAdmits(&snap, 1, 1) {
		t.Fatal("offload estimate bypassed loaded slot's full budget")
	}
	if got, known := snapshotStructuralBudget(&snap); !known || got != 1000 {
		t.Fatalf("live slot budget lost precedence: %d %v", got, known)
	}
}

func TestModelsUpdateRetainsOffloadDeclaration(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: "qwen"}})
	p := modelIndexRegister(t, reg, "provider", "qwen")
	merged, _ := reg.MergeProviderModels("provider", []protocol.ModelInfo{{ID: "qwen", ModelType: "qwen4_exp", SizeBytes: 100 << 30,
		EstimatedMemoryGB: 84, SSDOffloadedWeightBytes: 30 << 30}})
	if len(merged) != 1 {
		t.Fatal("model did not merge")
	}
	p.Mu().Lock()
	got := advertisedOffloadedMemoryGBLocked(p, "qwen")
	p.Mu().Unlock()
	if got != 84 {
		t.Fatalf("offload declaration lost in merge: %v", got)
	}
}

func TestOffloadedWeightsDoNotReplaceCatalogHardwareQualification(t *testing.T) {
	// A provider's valid live load estimate and the catalog's hardware-tier
	// contract are independent gates. No min-RAM claim is created by SSD offload.
	free := 90.0
	if admits, known := reportedFreeForLoadAdmitsWithOffload(104.649840190, 81.192351792, &free); !known || !admits {
		t.Fatal("valid live offloaded load estimate should fit this synthetic headroom")
	}
	if modelFitsHardware(0, 104.649840190, 128) {
		t.Fatal("unknown catalog requirement must keep the conservative static gate")
	}
	if modelFitsHardware(256, 104.649840190, 128) {
		t.Fatal("explicit catalog hardware requirement must not be bypassed")
	}
	if !modelFitsHardware(128, 104.649840190, 128) {
		t.Fatal("an independently approved catalog requirement should remain authoritative")
	}
}
