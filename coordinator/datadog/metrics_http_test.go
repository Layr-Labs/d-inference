package datadog

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func TestSeriesBufferLastWriteWinsAndCountSums(t *testing.T) {
	b := newSeriesBuffer()
	b.setGauge("providers.online", 10, []string{"env:prod"}, 100)
	b.setGauge("providers.online", 12, []string{"env:prod"}, 101) // same series → overwrite
	b.setGauge("providers.online", 3, []string{"version:0.6.3"}, 101)
	b.addCount("routing.load_failure_cooldowns", 1, []string{"model:m"}, 100)
	b.addCount("routing.load_failure_cooldowns", 1, []string{"model:m"}, 101) // same series → sum
	b.addCount("inference.zombie_stream_cancel", 1, nil, 101)

	gauges, counts := b.drain()
	if len(gauges) != 2 {
		t.Fatalf("expected 2 distinct gauge series, got %d", len(gauges))
	}
	for _, p := range gauges {
		if p.metric == "providers.online" && len(p.tags) == 1 && p.tags[0] == "env:prod" && p.value != 12 {
			t.Fatalf("gauge last-write-wins failed: got %v want 12", p.value)
		}
	}
	if len(counts) != 2 {
		t.Fatalf("expected 2 distinct count series, got %d", len(counts))
	}
	for _, p := range counts {
		if p.metric == "routing.load_failure_cooldowns" && p.value != 2 {
			t.Fatalf("count sum failed: got %v want 2", p.value)
		}
	}

	// Drain empties both maps.
	if g, c := b.drain(); g != nil || c != nil {
		t.Fatalf("drain should empty the buffer, got %d gauges %d counts", len(g), len(c))
	}
}

// Wire-contract test: flushSeries must produce the exact v1 /series shape —
// a payload regression here silently reproduces the missing-metrics gap this
// path exists to fix.
func TestFlushSeriesWireContract(t *testing.T) {
	type wireMetric struct {
		Metric   string       `json:"metric"`
		Points   [][2]float64 `json:"points"`
		Type     string       `json:"type"`
		Interval int64        `json:"interval"`
		Tags     []string     `json:"tags"`
		Host     string       `json:"host"`
	}
	var got struct {
		Series []wireMetric `json:"series"`
	}
	var apiKey string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		apiKey = r.Header.Get("Dd-Api-Key")
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	c := &Client{
		logger:            logger,
		apiKey:            "test-key",
		httpClient:        srv.Client(),
		seriesURL:         srv.URL,
		series:            newSeriesBuffer(),
		metricsTags:       []string{"env:test", "service:svc"},
		metricsHost:       "test-host",
		flushIntervalSecs: 5,
	}

	c.Gauge("providers.online", 42, []string{"region:us"})
	c.Incr("inference.zombie_stream_cancel", []string{"model:m"})
	c.Incr("inference.zombie_stream_cancel", []string{"model:m"})
	c.flushSeries()

	if apiKey != "test-key" {
		t.Fatalf("Dd-Api-Key header = %q, want test-key", apiKey)
	}
	if len(got.Series) != 2 {
		t.Fatalf("series count = %d, want 2", len(got.Series))
	}
	for _, m := range got.Series {
		switch m.Metric {
		case "d_inference.providers.online":
			if m.Type != "gauge" || m.Points[0][1] != 42 {
				t.Fatalf("gauge wire shape wrong: %+v", m)
			}
			if m.Points[0][0] < 1e9 {
				t.Fatalf("gauge timestamp not unix seconds: %v", m.Points[0][0])
			}
		case "d_inference.inference.zombie_stream_cancel":
			if m.Type != "count" || m.Points[0][1] != 2 || m.Interval != 5 {
				t.Fatalf("count wire shape wrong: %+v", m)
			}
		default:
			t.Fatalf("unexpected metric (prefix wrong?): %q", m.Metric)
		}
		if m.Host != "test-host" {
			t.Fatalf("host = %q, want test-host", m.Host)
		}
		// env/service base tags merged before per-point tags.
		if len(m.Tags) < 3 || m.Tags[0] != "env:test" || m.Tags[1] != "service:svc" {
			t.Fatalf("tags wrong: %v", m.Tags)
		}
	}

	// HTTP-exclusive: nothing should remain buffered, and a second flush is a no-op.
	c.flushSeries()
}
