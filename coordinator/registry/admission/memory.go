package admission

import "math"

const (
	// KVCacheBytesPerToken is the conservative legacy 7-8B KV estimate.
	KVCacheBytesPerToken = 400_000
	BytesPerGB           = 1 << 30
	// ColdLoadCatalogGBToMemGiB mirrors the provider's padded load quotation.
	ColdLoadCatalogGBToMemGiB = 1.2 * (1e9 / float64(int64(1)<<30))
	modelMemoryHeadroomFactor = 2.0
)

// ModelFitsHardware prefers the catalog's minimum RAM to the weight heuristic.
// Unknown hardware or model requirements fail open, as on the legacy path.
func ModelFitsHardware(minRAMGb int, modelSizeGB, totalMemoryGB float64) bool {
	if totalMemoryGB <= 0 {
		return true
	}
	if minRAMGb > 0 {
		return float64(minRAMGb) <= totalMemoryGB
	}
	if modelSizeGB > 0 {
		return modelSizeGB*modelMemoryHeadroomFactor <= totalMemoryGB
	}
	return true
}

// ReportedLoadAdmits compares a validated native LOAD estimate (when present)
// or the padded catalog size against the provider's authoritative load allowance.
func ReportedLoadAdmits(catalogSizeGB, nativeLoadGB, freeForLoadGB float64, reported bool) (bool, bool) {
	if !reported {
		return false, false
	}
	if math.IsNaN(freeForLoadGB) || math.IsInf(freeForLoadGB, 0) || freeForLoadGB < 0 {
		return false, true
	}
	required := nativeLoadGB
	if !finitePositive(required) {
		if !finitePositive(catalogSizeGB) {
			return false, false
		}
		required = catalogSizeGB * ColdLoadCatalogGBToMemGiB
	}
	return required <= freeForLoadGB, true
}

func finitePositive(value float64) bool {
	return value > 0 && !math.IsNaN(value) && !math.IsInf(value, 0)
}

// Memory is a detached physical-memory snapshot. NativeLoadGB has already been
// validated against the provider's payload declaration by the registry.
type Memory struct {
	ModelSizeGB, TotalGB, ActiveGB, NativeLoadGB, FreeForLoadGB float64
	ModelLoaded, AvailableOnDisk, LoadReported                  bool
	TotalPending                                                int
}

// MemoryAdmits is the legacy fallback after slot, pool and cold serviceability
// checks. Idle eviction is allowed only when there is no pending request.
func MemoryAdmits(snap Memory, requestTokens int64) bool {
	if snap.ModelSizeGB <= 0 || snap.TotalGB <= 0 {
		return true
	}
	required := snap.ModelSizeGB
	if snap.ModelLoaded {
		required = 0
	}
	tokens := requestTokens
	if tokens < 0 {
		tokens = 0
	}
	const maxTokensForCalc = 16 << 20
	if tokens > maxTokensForCalc {
		tokens = maxTokensForCalc
	}
	kvCacheGB := float64(tokens*KVCacheBytesPerToken) / float64(BytesPerGB)
	required += kvCacheGB
	if snap.AvailableOnDisk && !snap.ModelLoaded && snap.TotalPending == 0 {
		if admit, reported := ReportedLoadAdmits(snap.ModelSizeGB, snap.NativeLoadGB, snap.FreeForLoadGB, snap.LoadReported); reported {
			return admit
		}
		const osReserveGB = 4.0
		return snap.ModelSizeGB+kvCacheGB+osReserveGB <= snap.TotalGB
	}
	free := snap.TotalGB - snap.ActiveGB
	return free >= required
}
