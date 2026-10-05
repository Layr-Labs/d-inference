package service_test

import (
	"io"
	"log/slog"
	"strings"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/appattest/service"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// eventLog records emitted exchange events. Exchange workers emit from their
// own goroutines, so every access takes the lock.
type eventLog struct {
	mu     sync.Mutex
	events []map[string]any
}

func (l *eventLog) emit(fields map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = append(l.events, fields)
}

// outcomes lists every event as "stage:outcome".
func (l *eventLog) outcomes() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []string
	for _, e := range l.events {
		out = append(out, e["stage"].(string)+":"+e["outcome"].(string))
	}
	return out
}

// field returns the named field of the first event at stage:outcome.
func (l *eventLog) field(stage, outcome, name string) any {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, e := range l.events {
		if e["stage"] == stage && e["outcome"] == outcome {
			return e[name]
		}
	}
	return nil
}

// metricLog records metric hook calls; background workers call the hooks from
// their own goroutines, so every access takes the lock.
type metricLog struct {
	mu     sync.Mutex
	incr   []string
	counts map[string][]int64
	gauges map[string][]float64
	hist   map[string]int
}

func newMetricLog() *metricLog {
	return &metricLog{counts: map[string][]int64{}, gauges: map[string][]float64{}, hist: map[string]int{}}
}

func (m *metricLog) metrics() service.Metrics {
	return service.Metrics{
		Incr: m.increment,
		Count: func(name string, v int64, _ []string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.counts[name] = append(m.counts[name], v)
		},
		Gauge: func(name string, v float64, _ []string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.gauges[name] = append(m.gauges[name], v)
		},
		Histogram: func(name string, _ float64, _ []string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.hist[name]++
		},
	}
}

func (m *metricLog) increment(name string, tags []string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.incr = append(m.incr, strings.Join(append([]string{name}, tags...), "|"))
}

func (m *metricLog) count(name string) []int64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]int64(nil), m.counts[name]...)
}

func (m *metricLog) gauge(name string) []float64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]float64(nil), m.gauges[name]...)
}

func (m *metricLog) histogram(name string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.hist[name]
}

func (m *metricLog) incrCount(entry string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, e := range m.incr {
		if e == entry {
			n++
		}
	}
	return n
}
