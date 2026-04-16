package api

// In-process metrics registry.
//
// We roll our own minimal metrics rather than pulling in a Prometheus client.
// Rationale: one small file, no new dependency, and the Prometheus text format
// is trivially generated when/if we want to scrape. Metrics are read via the
// admin endpoint GET /v1/admin/metrics.

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
)

// MetricLabel is a single label (name, value) attached to a metric sample.
type MetricLabel struct {
	Name  string
	Value string
}

// Metrics is the registry of counters, histograms, and computed gauges.
type Metrics struct {
	mu         sync.RWMutex
	counters   map[string]*atomic.Int64
	histograms map[string]*Histogram
	gauges     map[string]GaugeFunc
}

// GaugeFunc returns a snapshotted gauge value computed at read time.
type GaugeFunc func() float64

// NewMetrics creates an empty registry.
func NewMetrics() *Metrics {
	return &Metrics{
		counters:   make(map[string]*atomic.Int64),
		histograms: make(map[string]*Histogram),
		gauges:     make(map[string]GaugeFunc),
	}
}

// IncCounter atomically increments the named counter by 1.
func (m *Metrics) IncCounter(name string, labels ...MetricLabel) {
	m.AddCounter(name, 1, labels...)
}

// AddCounter atomically adds delta to the named counter.
func (m *Metrics) AddCounter(name string, delta int64, labels ...MetricLabel) {
	key := metricKey(name, labels)
	m.mu.RLock()
	c, ok := m.counters[key]
	m.mu.RUnlock()
	if !ok {
		m.mu.Lock()
		c, ok = m.counters[key]
		if !ok {
			c = &atomic.Int64{}
			m.counters[key] = c
		}
		m.mu.Unlock()
	}
	c.Add(delta)
}

// ObserveHistogram records a sample into a histogram with default buckets.
func (m *Metrics) ObserveHistogram(name string, value float64, labels ...MetricLabel) {
	key := metricKey(name, labels)
	m.mu.RLock()
	h, ok := m.histograms[key]
	m.mu.RUnlock()
	if !ok {
		m.mu.Lock()
		h, ok = m.histograms[key]
		if !ok {
			h = NewHistogram(DefaultBuckets())
			m.histograms[key] = h
		}
		m.mu.Unlock()
	}
	h.Observe(value)
}

// RegisterGauge registers a computed gauge. fn is called each time the metric
// is read; it should be cheap.
func (m *Metrics) RegisterGauge(name string, fn GaugeFunc) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.gauges[name] = fn
}

// Snapshot returns a point-in-time view of all metrics.
func (m *Metrics) Snapshot() MetricsSnapshot {
	m.mu.RLock()
	defer m.mu.RUnlock()

	counters := make(map[string]int64, len(m.counters))
	for k, v := range m.counters {
		counters[k] = v.Load()
	}
	histograms := make(map[string]HistogramSnapshot, len(m.histograms))
	for k, v := range m.histograms {
		histograms[k] = v.Snapshot()
	}
	gauges := make(map[string]float64, len(m.gauges))
	for k, fn := range m.gauges {
		gauges[k] = fn()
	}
	return MetricsSnapshot{
		Counters:   counters,
		Histograms: histograms,
		Gauges:     gauges,
	}
}

// MetricsSnapshot is the JSON-friendly shape returned from GET /v1/admin/metrics.
type MetricsSnapshot struct {
	Counters   map[string]int64             `json:"counters"`
	Histograms map[string]HistogramSnapshot `json:"histograms"`
	Gauges     map[string]float64           `json:"gauges"`
}

// metricKey serializes name + labels into a stable map key used for lookups.
// Labels are sorted so the order callers pass them in doesn't matter.
func metricKey(name string, labels []MetricLabel) string {
	if len(labels) == 0 {
		return name
	}
	sort.SliceStable(labels, func(i, j int) bool { return labels[i].Name < labels[j].Name })
	var b strings.Builder
	b.WriteString(name)
	b.WriteByte('{')
	for i, l := range labels {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(l.Name)
		b.WriteByte('=')
		b.WriteString(l.Value)
	}
	b.WriteByte('}')
	return b.String()
}

// ---------------------------------------------------------------------------
// Histogram
// ---------------------------------------------------------------------------

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
	idx := sort.SearchFloat64s(h.buckets, v+1e-9)
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

// ---------------------------------------------------------------------------
// Prometheus text format
// ---------------------------------------------------------------------------

// RenderProm returns the snapshot in Prometheus exposition format.
func (s MetricsSnapshot) RenderProm() string {
	var b strings.Builder
	for name, v := range s.Counters {
		fmt.Fprintf(&b, "# TYPE %s counter\n%s %d\n", sanitizePromName(name), name, v)
	}
	for name, g := range s.Gauges {
		fmt.Fprintf(&b, "# TYPE %s gauge\n%s %g\n", sanitizePromName(name), name, g)
	}
	for name, h := range s.Histograms {
		promName := sanitizePromName(name)
		fmt.Fprintf(&b, "# TYPE %s histogram\n", promName)
		for i, bucket := range h.Buckets {
			fmt.Fprintf(&b, "%s_bucket{le=\"%g\"} %d\n", name, bucket, h.Counts[i])
		}
		fmt.Fprintf(&b, "%s_bucket{le=\"+Inf\"} %d\n", name, h.Counts[len(h.Counts)-1])
		fmt.Fprintf(&b, "%s_sum %g\n", name, h.Sum)
		fmt.Fprintf(&b, "%s_count %d\n", name, h.Count)
	}
	return b.String()
}

// sanitizePromName strips labels from a metric key, returning just the bare
// metric name (required for `# TYPE` lines).
func sanitizePromName(key string) string {
	if i := strings.IndexByte(key, '{'); i >= 0 {
		return key[:i]
	}
	return key
}
