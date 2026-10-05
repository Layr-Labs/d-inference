package ttftcalibration

import (
	"math"
	"sort"
)

const (
	WindowSize = 200
	WarmupObs  = 50
	RatioMin   = 0.2
	RatioMax   = 1.5
)

// ratioWindow caches the median on write, keeping the routing read path cheap.
// Raw ratios are retained so clamp recovery is immediate and outliers cannot
// poison the window as they would a mean or EWMA.
type ratioWindow struct {
	samples []float64
	next    int
	total   int64
	median  float64
}

func (w *ratioWindow) add(ratio float64) {
	if len(w.samples) < WindowSize {
		w.samples = append(w.samples, ratio)
	} else {
		w.samples[w.next] = ratio
		w.next = (w.next + 1) % WindowSize
	}
	w.total++
	w.median = medianOfSamples(w.samples)
}

func medianOfSamples(samples []float64) float64 {
	if len(samples) == 0 {
		return 1.0
	}
	sorted := make([]float64, len(samples))
	copy(sorted, samples)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid]
	}
	return (sorted[mid-1] + sorted[mid]) / 2
}

func clampRatio(ratio float64) float64 {
	if math.IsNaN(ratio) || ratio <= 0 {
		return 1.0
	}
	if ratio < RatioMin {
		return RatioMin
	}
	if ratio > RatioMax {
		return RatioMax
	}
	return ratio
}

// Apply scales only queued prefill, this prefill, and first decode. The cold-load
// penalty is a load-latency proxy, not throughput, and remains unscaled.
func Apply(rawMs, penalty, ratio float64) float64 {
	if rawMs <= 0 {
		return rawMs
	}
	if ratio == 1.0 {
		return rawMs
	}
	if penalty < 0 || penalty >= rawMs || math.IsInf(penalty, 0) {
		return rawMs
	}
	return penalty + (rawMs-penalty)*ratio
}
