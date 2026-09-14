package api

import (
	"log/slog"
	"net/http"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestInferenceErrorMetricEmitsReasonAndModel(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	srv.updateInferenceRouteOutcomeWithModel("req-metric", 1, "gpt-oss-20b", &store.InferenceRouteOutcome{
		FinalStatus: "error",
		ErrorClass:  "provider_error",
		ErrorCode:   http.StatusInternalServerError,
		ErrorReason: "jinja_null_bridge",
	})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	metrics := findMetrics(packets, metricInferenceError)
	if len(metrics) == 0 {
		t.Fatalf("missing %s metric; packets=%v", metricInferenceError, packets)
	}
	if !hasMetric(metrics, "reason:jinja_null_bridge") {
		t.Fatalf("missing reason tag; packets=%v", metrics)
	}
	if !hasMetric(metrics, "model:gpt-oss-20b") {
		t.Fatalf("missing model tag; packets=%v", metrics)
	}
}

func TestTimingDecompositionMetricEmitsSegments(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	srv.updateInferenceRouteOutcomeWithModel("req-timing", 1, "gpt-oss-20b", &store.InferenceRouteOutcome{
		FinalStatus:     "success",
		ParseMs:         1.5,
		ReserveMs:       2,
		RouteMs:         3,
		EncryptMs:       0, // not measured -> no sample
		QueueWaitMs:     4,
		DispatchMs:      5,
		TotalDurationMs: 20,
	})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	for _, seg := range []string{"parse_ms", "reserve_ms", "route_ms", "queue_wait_ms", "dispatch_ms", "total_duration_ms"} {
		metrics := findMetrics(packets, metricTimingSegmentPrefix+seg)
		if len(metrics) == 0 {
			t.Fatalf("missing %s%s metric; packets=%v", metricTimingSegmentPrefix, seg, packets)
		}
		if !hasMetric(metrics, "model:gpt-oss-20b") || !hasMetric(metrics, "final_status:success") {
			t.Fatalf("missing tags on %s; packets=%v", seg, metrics)
		}
	}
	if metrics := findMetrics(packets, metricTimingSegmentPrefix+"encrypt_ms"); len(metrics) != 0 {
		t.Fatalf("unmeasured segment must not emit a zero sample; packets=%v", metrics)
	}
}

func TestTimingDecompositionMetricSkipsCommitPrefill(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	// Commit-time pre-fill writes carry the decomposition but no FinalStatus;
	// emitting there would double-count a successful request (once at commit,
	// once at terminal).
	srv.updateInferenceRouteOutcomeWithModel("req-prefill", 1, "gpt-oss-20b", &store.InferenceRouteOutcome{
		ParseMs:         1.5,
		TotalDurationMs: 20,
	})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	if metrics := findMetrics(packets, metricTimingSegmentPrefix); len(metrics) != 0 {
		t.Fatalf("commit pre-fill must not emit timing metrics; packets=%v", metrics)
	}
}
