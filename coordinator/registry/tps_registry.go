package registry

import (
	"sync"
)

// TPSRegistry aggregates observed decode TPS values from heartbeats,
// keyed by model and chip family. Used to provide fleet-calibrated
// estimates for providers that haven't reported observed TPS yet.
//
// It holds two independent sample stores with the same 50-sample FIFO+median
// shape but deliberately different ingest semantics:
//
//   - samples (Record/Median): EVERY reported EWMA, including under-load ones.
//     Feeds fleetMedianTPS → TTFT estimation, whose load-inclusive semantics
//     are intentional (an estimate of what a request will actually see).
//   - soloSamples (RecordSolo/SoloMedian, solo_tps.go): only samples taken
//     while the WHOLE box was uncontended. Feeds the quality-concurrency cap,
//     which needs a static solo rate that cannot collapse under the very
//     overload the cap exists to prevent.
//
// Every read-side aggregate (medians, the cross-class solo aggregate) is
// maintained on write and served as an O(1), allocation-free lookup — see
// tps_median_cache.go. The routing scan reads them once per provider.
type TPSRegistry struct {
	mu          sync.RWMutex
	samples     map[tpsKey][]float64
	soloSamples map[tpsKey][]float64
	maxSamples  int

	// medians caches the median of samples[key]; refreshed by Record.
	medians map[tpsKey]float64
	// soloByModel caches the solo median + count per model → chip class;
	// refreshed by RecordSolo. soloAllChips is the per-model cross-class
	// aggregate derived from it.
	soloByModel  map[string]map[string]tpsSampleStat
	soloAllChips map[string]soloAllChipsStat
	// scratch is the write-side sort buffer (cap maxSamples), used only under
	// the write lock so no read ever allocates or sorts.
	scratch []float64
}

type tpsKey struct {
	Model      string
	ChipFamily string
}

func NewTPSRegistry() *TPSRegistry {
	const maxSamples = 50 // keep last 50 observations per model+chip
	return &TPSRegistry{
		samples:      make(map[tpsKey][]float64),
		soloSamples:  make(map[tpsKey][]float64),
		maxSamples:   maxSamples,
		medians:      make(map[tpsKey]float64),
		soloByModel:  make(map[string]map[string]tpsSampleStat),
		soloAllChips: make(map[string]soloAllChipsStat),
		scratch:      make([]float64, 0, maxSamples),
	}
}

// Record adds an observed TPS value for the given model and chip family.
// Called from heartbeat processing when a provider reports ObservedDecodeTPS > 0.
func (r *TPSRegistry) Record(model, chipFamily string, tps float64) {
	if tps <= 0 || model == "" {
		return
	}
	key := tpsKey{Model: model, ChipFamily: chipFamily}
	r.mu.Lock()
	defer r.mu.Unlock()
	samples := appendRingSample(r.samples[key], tps, r.maxSamples)
	r.samples[key] = samples
	r.medians[key] = r.medianOfRingLocked(samples)
}

// Median returns the median observed TPS for the given model and chip family.
// Returns 0 if no observations exist. O(1), allocation-free (the value is
// maintained by Record).
func (r *TPSRegistry) Median(model, chipFamily string) float64 {
	key := tpsKey{Model: model, ChipFamily: chipFamily}
	r.mu.RLock()
	median := r.medians[key]
	r.mu.RUnlock()
	return median
}
