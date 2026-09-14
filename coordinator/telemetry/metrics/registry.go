package metrics

import (
	"sync"
	"sync/atomic"
)

// Label is a single label (name, value) attached to a metric sample.
type Label struct {
	Name  string
	Value string
}

// Registry is the registry of counters, histograms, and computed gauges.
type Registry struct {
	mu            sync.RWMutex
	counters      map[string]*atomic.Int64
	histograms    map[string]*Histogram
	gauges        map[string]GaugeFunc
	snapshotHooks []func()
}

// GaugeFunc returns a snapshotted gauge value computed at read time.
type GaugeFunc func() float64

// New creates an empty registry.
func New() *Registry {
	return &Registry{
		counters:   make(map[string]*atomic.Int64),
		histograms: make(map[string]*Histogram),
		gauges:     make(map[string]GaugeFunc),
	}
}

// IncCounter atomically increments the named counter by 1.
func (m *Registry) IncCounter(name string, labels ...Label) {
	m.AddCounter(name, 1, labels...)
}

// IncCounterEvent is the cross-package adapter used by
// telemetry.Emitter — hides our Label type behind a stable signature.
func (m *Registry) IncCounterEvent(source, severity, kind string) {
	m.IncCounter("telemetry_events_total",
		Label{"source", source},
		Label{"severity", severity},
		Label{"kind", kind},
	)
}

// AddCounter atomically adds delta to the named counter.
func (m *Registry) AddCounter(name string, delta int64, labels ...Label) {
	key := Key(name, labels)
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
func (m *Registry) ObserveHistogram(name string, value float64, labels ...Label) {
	key := Key(name, labels)
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
func (m *Registry) RegisterGauge(name string, fn GaugeFunc) {
	m.RegisterGaugeLabels(name, fn)
}

// RegisterGaugeLabels registers a computed gauge with a bounded label set.
func (m *Registry) RegisterGaugeLabels(name string, fn GaugeFunc, labels ...Label) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.gauges[Key(name, labels)] = fn
}

// RegisterSnapshotHook registers bounded work that runs once before every
// metrics snapshot. Gauges that share an expensive source can refresh one
// cached aggregate here instead of recomputing it independently.
func (m *Registry) RegisterSnapshotHook(fn func()) {
	if fn == nil {
		return
	}
	m.mu.Lock()
	m.snapshotHooks = append(m.snapshotHooks, fn)
	m.mu.Unlock()
}

// Snapshot returns a point-in-time view of all metrics.
func (m *Registry) Snapshot() Snapshot {
	m.mu.RLock()
	hooks := append([]func(){}, m.snapshotHooks...)
	counterSources := make(map[string]*atomic.Int64, len(m.counters))
	for key, counter := range m.counters {
		counterSources[key] = counter
	}
	histogramSources := make(map[string]*Histogram, len(m.histograms))
	for key, histogram := range m.histograms {
		histogramSources[key] = histogram
	}
	gaugeSources := make(map[string]GaugeFunc, len(m.gauges))
	for key, gauge := range m.gauges {
		gaugeSources[key] = gauge
	}
	m.mu.RUnlock()

	for _, hook := range hooks {
		hook()
	}

	counters := make(map[string]int64, len(counterSources))
	for k, v := range counterSources {
		counters[k] = v.Load()
	}
	histograms := make(map[string]HistogramSnapshot, len(histogramSources))
	for k, v := range histogramSources {
		histograms[k] = v.Snapshot()
	}
	gauges := make(map[string]float64, len(gaugeSources))
	for k, fn := range gaugeSources {
		gauges[k] = fn()
	}
	return Snapshot{
		Counters:   counters,
		Histograms: histograms,
		Gauges:     gauges,
	}
}

// Snapshot is the JSON-friendly shape returned from GET /v1/admin/metrics.
type Snapshot struct {
	Counters   map[string]int64             `json:"counters"`
	Histograms map[string]HistogramSnapshot `json:"histograms"`
	Gauges     map[string]float64           `json:"gauges"`
}
