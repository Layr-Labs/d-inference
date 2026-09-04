package api

import (
	"log/slog"
	"net/http"
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

	// Block the recorder behind a held write lock so the wait is measurable.
	release := reg.HoldWriteLockForTest()
	go func() {
		time.Sleep(30 * time.Millisecond)
		release()
	}()
	reg.ClearDispatchLoadCooldown(p.ID, model)

	packet := waitForMetric(t, collector, "registry.mu.write_wait_ms")
	if !strings.Contains(packet, "site:dispatch_load_cooldown") {
		t.Fatalf("lock-wait histogram missing the site tag: %s", packet)
	}
	if !strings.Contains(packet, "|h|") {
		t.Fatalf("lock-wait metric is not a histogram: %s", packet)
	}
}

// TestRoutingScansCounterEmittedPerDecision: the decision's ScanCount is
// emitted as the routing.scans counter with the model and outcome tags; a
// plan-based retry (zero scans) emits nothing.
func TestRoutingScansCounterEmittedPerDecision(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	srv := newTestServerForDispatch(t)
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	req, _ := http.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	d := &dispatchState{s: srv, r: req, model: "scan-metric-model", attempt: 0}
	d.recordRoutingDecision(registry.RoutingDecision{Model: d.model, ScanCount: 2}, "no provider available", "")
	packet := waitForMetric(t, collector, "routing.scans")
	if !strings.Contains(packet, "routing.scans:2|c|") || !strings.Contains(packet, "model:scan-metric-model") || !strings.Contains(packet, "outcome:no_provider") {
		t.Fatalf("routing.scans packet = %s, want count 2 tagged with the model and outcome", packet)
	}

	d.recordRoutingDecision(registry.RoutingDecision{Model: d.model, ScanCount: 0}, "no provider available", "")
	time.Sleep(50 * time.Millisecond)
	for _, p := range collector.drain() {
		if strings.Contains(p, "routing.scans") {
			t.Fatalf("a zero-scan decision emitted routing.scans: %s", p)
		}
	}
}
