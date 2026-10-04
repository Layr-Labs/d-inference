package api_test

import (
	"log/slog"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// awaitMetric polls the collector until a packet for metric arrives or the
// timeout lapses (the DogStatsD client may buffer briefly). Matched as a
// substring: the client prefixes every name with the configured namespace.
func awaitMetric(t *testing.T, c *udpCollector, metric string, timeout time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		for _, p := range c.drain() {
			if strings.Contains(p, metric+":") {
				return p
			}
		}
	}
	t.Fatalf("no %s packet within %v", metric, timeout)
	return ""
}

// TestRegistryGateWaitHistogramTaggedBySite: NewServer wires the registry's
// gate-wait observer to the registry.gate.wait_ms histogram, tagged with the
// recorder site, so the per-identity locks that replaced the request-path
// registry write lock stay observable.
func TestRegistryGateWaitHistogramTaggedBySite(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	options := identitygate.DefaultOptions()
	entered, released, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var hold atomic.Bool
	options.Now = func() time.Time {
		if hold.CompareAndSwap(true, false) {
			close(entered)
			<-released
		}
		return time.Now()
	}
	gates := identitygate.New(logger, &options)
	reg := registry.NewWithDependencies(logger, registry.Dependencies{IdentityGates: gates})
	srv := production.NewServer(reg, memory.NewMemory(store.Config{AdminKey: "test-key"}), production.ServerConfig{}, logger)
	defer srv.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	const model = "gate-wait-metric-model"
	p := makeRoutableProvider(t, reg, "gate-wait-metric-provider", model)

	// Block the recorder behind its identity's held gate so the wait is
	// measurable (well above the 1 ms reporting threshold).
	// The real outcome recorder samples its clock while holding the gate.
	// A neutral capacity shed leaves the health history unchanged.
	hold.Store(true)
	go func() {
		reg.RecordProviderOutcome(p.ID, false, 429, "")
		close(finished)
	}()
	<-entered
	var once sync.Once
	release := func() { once.Do(func() { close(released) }) }
	defer func() { release(); <-finished }()
	go func() {
		time.Sleep(30 * time.Millisecond)
		release()
	}()
	reg.RecordProviderOutcome(p.ID, true, 200, "")

	packet := awaitMetric(t, collector, "registry.gate.wait_ms", 5*time.Second)
	if !strings.Contains(packet, "site:breaker") {
		t.Fatalf("gate-wait histogram missing the site tag: %s", packet)
	}
	if !strings.Contains(packet, "|h|") {
		t.Fatalf("gate-wait metric is not a histogram: %s", packet)
	}
}
