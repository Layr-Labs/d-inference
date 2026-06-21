package api

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestIdleGapBucket(t *testing.T) {
	cases := []struct {
		ms   float64
		want string
	}{
		{0, "lt_1s"}, {999, "lt_1s"}, {1000, "1_5s"}, {4999, "1_5s"},
		{5000, "5_15s"}, {14999, "5_15s"}, {15000, "15_30s"}, {29999, "15_30s"},
		{30000, "gte_30s"}, {120000, "gte_30s"},
	}
	for _, tc := range cases {
		if got := idleGapBucket(tc.ms); got != tc.want {
			t.Errorf("idleGapBucket(%v) = %q, want %q", tc.ms, got, tc.want)
		}
	}
}

func TestCancelMetricsEmit(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	srv.updateInferenceRouteOutcomeWithModel("req-cancel-metric", 1, "gpt-oss-20b", &store.InferenceRouteOutcome{
		FinalStatus:              "partial_success",
		ErrorClass:               "no_terminal_after_cancel",
		CancelPhase:              cancelPhaseAfterFirstToken,
		CancelSource:             cancelSourceStreamIdleTimeout,
		PartialSettlementStatus:  partialSettlementExpired,
		EstimatedDeliveredTokens: 37,
		MaxIdleGapMs:             20000,
	})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	cancel := findMetrics(packets, metricCancel)
	if len(cancel) == 0 {
		t.Fatalf("missing %s metric; packets=%v", metricCancel, packets)
	}
	if !hasMetric(cancel, "phase:after_first_token") || !hasMetric(cancel, "source:stream_idle_timeout") || !hasMetric(cancel, "model:gpt-oss-20b") {
		t.Fatalf("inference.cancel missing expected tags; metrics=%v", cancel)
	}
	if settle := findMetrics(packets, metricCancelPartialSettlement); len(settle) == 0 || !hasMetric(settle, "status:expired") {
		t.Fatalf("missing partial_settlement status:expired; packets=%v", packets)
	}
	if delivered := findMetrics(packets, metricCancelDeliveredTokens); len(delivered) == 0 {
		t.Fatalf("missing %s; packets=%v", metricCancelDeliveredTokens, packets)
	}
	if idle := findMetrics(packets, metricStreamIdleGap); len(idle) == 0 || !hasMetric(idle, "bucket:15_30s") {
		t.Fatalf("missing idle_gap bucket:15_30s; packets=%v", packets)
	}
}

func TestCancelMetricsSkippedForNonCancel(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	srv.updateInferenceRouteOutcomeWithModel("req-success", 1, "gpt-oss-20b", &store.InferenceRouteOutcome{
		FinalStatus:      "success",
		PromptTokens:     10,
		CompletionTokens: 20,
	})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	if cancel := findMetrics(packets, metricCancel); len(cancel) != 0 {
		t.Fatalf("inference.cancel should not emit for a successful outcome; metrics=%v", cancel)
	}
}
