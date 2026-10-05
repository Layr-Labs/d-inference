// Package series accumulates metric points for the Datadog HTTP transport.
package series

import (
	"strings"
	"sync"
)

// Buffer accumulates metric points between flushes: gauges are
// last-write-wins per (metric, tags) series; counters sum per series over the
// flush interval — both matching what a local agent would submit.
type Buffer struct {
	mu     sync.Mutex
	gauges map[string]Point
	counts map[string]Point
}

type Point struct {
	Metric    string
	Tags      []string
	Value     float64
	Timestamp int64
}

func New() *Buffer {
	return &Buffer{
		gauges: make(map[string]Point),
		counts: make(map[string]Point),
	}
}

func seriesKey(metric string, tags []string) string {
	return metric + "|" + strings.Join(tags, ",")
}

func (b *Buffer) SetGauge(metric string, value float64, tags []string, timestamp int64) {
	key := seriesKey(metric, tags)
	b.mu.Lock()
	b.gauges[key] = Point{Metric: metric, Tags: tags, Value: value, Timestamp: timestamp}
	b.mu.Unlock()
}

func (b *Buffer) AddCount(metric string, value float64, tags []string, timestamp int64) {
	key := seriesKey(metric, tags)
	b.mu.Lock()
	p, ok := b.counts[key]
	if !ok {
		p = Point{Metric: metric, Tags: tags}
	}
	p.Value += value
	p.Timestamp = timestamp
	b.counts[key] = p
	b.mu.Unlock()
}

// Drain returns and clears the buffered gauges and counts.
func (b *Buffer) Drain() (gauges, counts []Point) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, p := range b.gauges {
		gauges = append(gauges, p)
	}
	for _, p := range b.counts {
		counts = append(counts, p)
	}
	b.gauges = make(map[string]Point)
	b.counts = make(map[string]Point)
	return gauges, counts
}
