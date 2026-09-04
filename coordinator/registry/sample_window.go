package registry

import (
	"math"
	"sort"
)

// sampleWindow is a fixed-capacity ring of float64 samples for the online
// calibrators (completion_calibration.go). Statistics are computed by the
// owner on write and cached, so the routing-path read is a plain load — the
// same shape as ttftRatioWindow, generalized over capacity.
type sampleWindow struct {
	capacity int
	samples  []float64
	next     int
	total    int64
}

func newSampleWindow(capacity int) sampleWindow {
	if capacity <= 0 {
		capacity = 1
	}
	return sampleWindow{capacity: capacity}
}

// add appends a sample, overwriting the oldest once the window is full.
func (w *sampleWindow) add(v float64) {
	if w.capacity <= 0 {
		w.capacity = 1
	}
	if len(w.samples) < w.capacity {
		w.samples = append(w.samples, v)
	} else {
		w.samples[w.next] = v
		w.next = (w.next + 1) % w.capacity
	}
	w.total++
}

// sorted returns an ascending copy of the current samples.
func (w *sampleWindow) sorted() []float64 {
	out := make([]float64, len(w.samples))
	copy(out, w.samples)
	sort.Float64s(out)
	return out
}

// percentileOfSorted is the nearest-rank percentile (q in [0,1]) of an
// ascending slice; 0 for an empty slice.
func percentileOfSorted(sorted []float64, q float64) float64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	if q <= 0 {
		return sorted[0]
	}
	if q >= 1 {
		return sorted[n-1]
	}
	rank := int(math.Ceil(q*float64(n))) - 1
	if rank < 0 {
		rank = 0
	}
	if rank >= n {
		rank = n - 1
	}
	return sorted[rank]
}
