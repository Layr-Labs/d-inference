package api

import (
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func waitForMetric(t *testing.T, collector *udpCollector, substr string) string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	var seen []string
	for time.Now().Before(deadline) {
		seen = append(seen, collector.drain()...)
		for _, p := range seen {
			if strings.Contains(p, substr) {
				return p
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("metric %q never emitted; saw %v", substr, seen)
	return ""
}

// TestRegistryLockWaitHistogramTaggedBySite: NewServer wires the registry's
// lock-wait observer to the registry.mu.write_wait_ms histogram, tagged with
// the call site.
func TestRegistryLockWaitHistogramTaggedBySite(t *testing.T) {
	t.Setenv("EIGENINFERENCE_RESERVE_COMMIT_MODE", "global")
	collector := newUDPCollector(t)
	defer collector.Close()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "test-key"}), ServerConfig{}, logger)
	defer srv.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	const model = "lock-wait-metric-model"
	p := makeRoutableProvider(t, reg, "lock-wait-metric-provider", model)

	// The global compatibility commit still emits the write-lock metric.
	reserved, _, _ := reg.ReserveProviderWithPlan(model, &registry.PendingRequest{RequestID: "global-metric", Model: model, EstimatedPromptTokens: 1})
	if reserved == nil {
		t.Fatal("global reservation failed")
	}
	defer p.RemovePending("global-metric")

	packet := waitForMetric(t, collector, "registry.mu.write_wait_ms")
	if !strings.Contains(packet, "site:commit") {
		t.Fatalf("lock-wait histogram missing the site tag: %s", packet)
	}
	if !strings.Contains(packet, "|h|") {
		t.Fatalf("lock-wait metric is not a histogram: %s", packet)
	}
}
