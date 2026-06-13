package api

import (
	"log/slog"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCounterIncrements(t *testing.T) {
	m := NewMetrics()
	m.IncCounter("foo")
	m.IncCounter("foo")
	m.AddCounter("foo", 3)
	snap := m.Snapshot()
	if snap.Counters["foo"] != 5 {
		t.Fatalf("got %d want 5", snap.Counters["foo"])
	}
}

func TestCounterLabelsStableRegardlessOfOrder(t *testing.T) {
	m := NewMetrics()
	m.IncCounter("x", MetricLabel{"a", "1"}, MetricLabel{"b", "2"})
	m.IncCounter("x", MetricLabel{"b", "2"}, MetricLabel{"a", "1"})
	snap := m.Snapshot()
	// Should hit the same key.
	if len(snap.Counters) != 1 {
		t.Fatalf("expected 1 counter key, got %d: %+v", len(snap.Counters), snap.Counters)
	}
	for _, v := range snap.Counters {
		if v != 2 {
			t.Fatalf("value: got %d want 2", v)
		}
	}
}

func TestHistogramBucketing(t *testing.T) {
	h := NewHistogram([]float64{1, 5, 10})
	h.Observe(0.5) // -> bucket 0
	h.Observe(3)   // -> bucket 1
	h.Observe(7)   // -> bucket 2
	h.Observe(100) // -> +Inf bucket
	snap := h.Snapshot()
	// Cumulative counts: [1, 2, 3, 4]
	if snap.Counts[0] != 1 || snap.Counts[1] != 2 || snap.Counts[2] != 3 || snap.Counts[3] != 4 {
		t.Fatalf("cumulative: %+v", snap.Counts)
	}
	if snap.Count != 4 {
		t.Fatalf("count: got %d want 4", snap.Count)
	}
	if snap.Sum != 110.5 {
		t.Fatalf("sum: got %v want 110.5", snap.Sum)
	}
}

func TestGaugeReadsEachCall(t *testing.T) {
	m := NewMetrics()
	var n float64 = 1
	m.RegisterGauge("dyn", func() float64 {
		n *= 2
		return n
	})
	s1 := m.Snapshot()
	if s1.Gauges["dyn"] != 2 {
		t.Fatalf("first: %v", s1.Gauges["dyn"])
	}
	s2 := m.Snapshot()
	if s2.Gauges["dyn"] != 4 {
		t.Fatalf("second: %v", s2.Gauges["dyn"])
	}
}

func TestRenderProm(t *testing.T) {
	m := NewMetrics()
	m.IncCounter("c", MetricLabel{"k", "v"})
	m.ObserveHistogram("h", 3, MetricLabel{"k", "v"})
	m.RegisterGauge("g", func() float64 { return 7 })
	text := m.Snapshot().RenderProm()
	for _, want := range []string{"# TYPE c counter", "# TYPE g gauge", "# TYPE h histogram", "h_count"} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in prom output:\n%s", want, text)
		}
	}
}

func TestDDTagsToMetricLabels(t *testing.T) {
	labels := ddTagsToMetricLabels([]string{"model:test-model", "outcome:selected", "badtag"})
	if len(labels) != 2 {
		t.Fatalf("expected 2 labels, got %d: %+v", len(labels), labels)
	}
	if labels[0].Name != "model" || labels[0].Value != "test-model" {
		t.Errorf("first label = %+v, want model:test-model", labels[0])
	}
}

func TestServerRegistersWarmupETAGauge(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	srv := NewServer(reg, st, ServerConfig{}, logger)
	snap := srv.Metrics().Snapshot()
	if _, ok := snap.Gauges["warming.max_warmup_eta_seconds"]; !ok {
		t.Fatalf("expected warming.max_warmup_eta_seconds gauge to be registered, got %+v", snap.Gauges)
	}
}
