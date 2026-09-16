package routingcost

import (
	"math"
	"sort"
)

type ttftCalibrationKey struct {
	model string
	chip  string // "" = model-level aggregate
}

// ttftRatioWindow is a fixed-size ring of actual/predicted ratio samples with a
// cached median (recomputed on write so the routing-path read is a plain load).
type ttftRatioWindow struct {
	samples []float64
	next    int
	total   int64
	median  float64
}

func (w *ttftRatioWindow) add(ratio float64) {
	if len(w.samples) < ttftCalibrationWindowSize {
		w.samples = append(w.samples, ratio)
	} else {
		w.samples[w.next] = ratio
		w.next = (w.next + 1) % ttftCalibrationWindowSize
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

func clampTTFTCalibrationRatio(ratio float64) float64 {
	if math.IsNaN(ratio) || ratio <= 0 {
		return 1.0
	}
	if ratio < ttftCalibrationRatioMin {
		return ttftCalibrationRatioMin
	}
	if ratio > ttftCalibrationRatioMax {
		return ttftCalibrationRatioMax
	}
	return ratio
}
