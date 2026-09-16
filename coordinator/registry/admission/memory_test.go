package admission

import (
	"testing"
)

func TestFreeMemoryAdmitsTokenBudget(t *testing.T) {
	// With token budget, should use budget-based admission.
	snap := Snapshot{
		ActiveTokenBudgetUsed: 28_000,
		ActiveTokenBudgetMax:  32_768,
		ModelSizeGB:           8,
		TotalMemoryGB:         64,
	}
	// Request for 500 + 4096 = 4596 tokens. 28000 + 4596 = 32596 <= 32768. Fits.
	if !testPolicy.FreeMemoryAdmits(snapPtr(snap), 500, 4096) {
		t.Fatal("should admit: 28000 + 4596 = 32596 <= 32768")
	}
	// Request for 500 + 4500 = 5000 tokens. 28000 + 5000 = 33000 > 32768. Rejected.
	if testPolicy.FreeMemoryAdmits(snapPtr(snap), 500, 4500) {
		t.Fatal("should reject: 28000 + 5000 = 33000 > 32768")
	}
}

func TestFreeMemoryAdmitsIncludesQueuedBudget(t *testing.T) {
	snap := Snapshot{
		ActiveTokenBudgetUsed: 20_000,
		ActiveTokenBudgetMax:  32_768,
		QueuedTokenBudget:     10_000,
		ModelSizeGB:           8,
		TotalMemoryGB:         64,
	}
	// active(20K) + queued(10K) + request(500+4096=4596) = 34596 > 32768. Rejected.
	if testPolicy.FreeMemoryAdmits(snapPtr(snap), 500, 4096) {
		t.Fatal("should reject: active + queued + request exceeds budget")
	}
	// Without queued budget: active(20K) + request(4596) = 24596 <= 32768. Fits.
	snap.QueuedTokenBudget = 0
	if !testPolicy.FreeMemoryAdmits(snapPtr(snap), 500, 4096) {
		t.Fatal("should admit when queued budget is zero")
	}
}

func TestFreeMemoryAdmitsFallsBackWithoutBudget(t *testing.T) {
	// Without token budget (max=0), should fall back to memory-based check.
	snap := Snapshot{
		ActiveTokenBudgetUsed: 0,
		ActiveTokenBudgetMax:  0,
		ModelSizeGB:           8,
		TotalMemoryGB:         64,
		GPUMemoryActiveGB:     10,
		ModelLoaded:           true,
	}
	// Model already loaded, so only KV matters. Lots of free memory.
	if !testPolicy.FreeMemoryAdmits(snapPtr(snap), 100, 256) {
		t.Fatal("should admit with plenty of free memory in legacy mode")
	}
}

// When the provider reports freeForLoadGB, the cold-load gate uses it as the
// single source of truth: admit iff the model's weights fit, regardless of the
// coarse total-memory heuristic.
func TestFreeMemoryAdmitsColdLoadUsesReportedFreeForLoad(t *testing.T) {
	freeForLoad := 9.0 // e.g. a 24GB box reports ~9GB loadable
	base := Snapshot{
		TotalMemoryGB:   64, // heuristic would happily admit; reported value must win
		AvailableOnDisk: true,
		ModelLoaded:     false,
		TotalPending:    0,
		FreeForLoadGB:   &freeForLoad,
	}

	fits := base
	fits.ModelSizeGB = 8 // 8 <= 9 → admit
	if !testPolicy.FreeMemoryAdmits(snapPtr(fits), 100, 256) {
		t.Fatal("8GB model must be admitted: fits in reported 9GB free-for-load")
	}

	tooBig := base
	tooBig.ModelSizeGB = 14 // 14 > 9 → reject, even though heuristic on 64GB would admit
	if testPolicy.FreeMemoryAdmits(snapPtr(tooBig), 100, 256) {
		t.Fatal("14GB model must be rejected: exceeds reported 9GB free-for-load")
	}
}

// A reported 0 ("can't load anything now") must reject any cold load, not fall
// back to the heuristic (nil is the only fallback trigger).
func TestFreeMemoryAdmitsColdLoadReportedZeroRejects(t *testing.T) {
	zero := 0.0
	snap := Snapshot{
		ModelSizeGB:     4,
		TotalMemoryGB:   64,
		AvailableOnDisk: true,
		ModelLoaded:     false,
		TotalPending:    0,
		FreeForLoadGB:   &zero,
	}
	if testPolicy.FreeMemoryAdmits(snapPtr(snap), 100, 256) {
		t.Fatal("reported free-for-load 0 must reject a cold load")
	}
}

// The cold-load gate must compare against the provider's PADDED-GiB load basis,
// not the raw catalog size, or a near-threshold model whose raw size fits but
// whose padded estimate doesn't gets routed and then 503'd at load (Codex #390).
func TestFreeMemoryAdmitsColdLoadNormalizesCatalogSize(t *testing.T) {
	free := 10.0
	// Raw 9.5GB naively "fits" 10, but padded 9.5*1.1176≈10.6 > 10 → must reject.
	snap := Snapshot{
		ModelSizeGB:     9.5,
		TotalMemoryGB:   64,
		AvailableOnDisk: true,
		ModelLoaded:     false,
		TotalPending:    0,
		FreeForLoadGB:   &free,
	}
	if testPolicy.FreeMemoryAdmits(snapPtr(snap), 100, 256) {
		t.Fatal("near-threshold model must reject: padded estimate exceeds reported free-for-load")
	}
	snap.ModelSizeGB = 8 // padded 8*1.1176≈8.94 <= 10 → admit
	if !testPolicy.FreeMemoryAdmits(snapPtr(snap), 100, 256) {
		t.Fatal("8GB model must admit: padded estimate fits reported free-for-load")
	}
}

// Legacy provider (freeForLoadGB nil) falls back to the total-memory heuristic.
func TestFreeMemoryAdmitsColdLoadFallsBackWhenUnreported(t *testing.T) {
	snap := Snapshot{
		ModelSizeGB:     16,
		TotalMemoryGB:   64, // 16 + ~0 + 4 = 20 <= 64 → admit via heuristic
		AvailableOnDisk: true,
		ModelLoaded:     false,
		TotalPending:    0,
		FreeForLoadGB:   nil,
	}
	if !testPolicy.FreeMemoryAdmits(snapPtr(snap), 100, 256) {
		t.Fatal("legacy provider must fall back to the total-memory heuristic (admit)")
	}
}
