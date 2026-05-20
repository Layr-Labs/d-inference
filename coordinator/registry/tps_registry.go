package registry

import (
	"sort"
	"sync"
)

// TPSRegistry aggregates observed decode TPS values from heartbeats,
// keyed by model and chip family. Used to provide fleet-calibrated
// estimates for providers that haven't reported observed TPS yet.
type TPSRegistry struct {
	mu         sync.RWMutex
	samples    map[tpsKey][]float64
	maxSamples int
}

type tpsKey struct {
	Model      string
	ChipFamily string
}

func NewTPSRegistry() *TPSRegistry {
	return &TPSRegistry{
		samples:    make(map[tpsKey][]float64),
		maxSamples: 50, // keep last 50 observations per model+chip
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
	samples := r.samples[key]
	if len(samples) >= r.maxSamples {
		// Drop oldest sample (FIFO ring)
		samples = samples[1:]
	}
	r.samples[key] = append(samples, tps)
}

// Median returns the median observed TPS for the given model and chip family.
// Returns 0 if no observations exist.
func (r *TPSRegistry) Median(model, chipFamily string) float64 {
	key := tpsKey{Model: model, ChipFamily: chipFamily}
	r.mu.RLock()
	samples := r.samples[key]
	sorted := make([]float64, len(samples))
	copy(sorted, samples)
	r.mu.RUnlock()
	if len(sorted) == 0 {
		return 0
	}
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 0 {
		return (sorted[mid-1] + sorted[mid]) / 2
	}
	return sorted[mid]
}
