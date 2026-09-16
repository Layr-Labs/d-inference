package metrics

import (
	"sort"
	"sync"
)

// Histogram is a fixed-bucket histogram suitable for latency measurements.
type Histogram struct {
	mu      sync.Mutex
	buckets []float64 // upper bounds, ascending
	counts  []int64   // len(buckets)+1 — last is +Inf
	sum     float64
	count   int64
}

// DefaultBuckets returns a set of latency buckets from 5 ms to 60 s.
func DefaultBuckets() []float64 {
	return []float64{5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000}
}

// NewHistogram builds a histogram for the given bucket upper bounds (in the
// unit of values being observed — typically milliseconds).
func NewHistogram(buckets []float64) *Histogram {
	return &Histogram{
		buckets: buckets,
		counts:  make([]int64, len(buckets)+1),
	}
}

// Observe records a single sample.
func (h *Histogram) Observe(v float64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sum += v
	h.count++
	idx := sort.SearchFloat64s(h.buckets, v)
	h.counts[idx]++
}

// HistogramSnapshot is the JSON-friendly shape for a histogram.
type HistogramSnapshot struct {
	Buckets []float64 `json:"buckets"` // upper bounds (last entry is +Inf, represented as 0 in index len-1)
	Counts  []int64   `json:"counts"`  // cumulative counts per bucket
	Sum     float64   `json:"sum"`
	Count   int64     `json:"count"`
}

// Snapshot copies the histogram state. Counts are cumulative (prometheus-style).
func (h *Histogram) Snapshot() HistogramSnapshot {
	h.mu.Lock()
	defer h.mu.Unlock()
	cum := make([]int64, len(h.counts))
	var running int64
	for i, c := range h.counts {
		running += c
		cum[i] = running
	}
	return HistogramSnapshot{
		Buckets: append([]float64{}, h.buckets...),
		Counts:  cum,
		Sum:     h.sum,
		Count:   h.count,
	}
}
