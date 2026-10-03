package observation

import (
	"context"
	"testing"
	"time"
)

func TestDefaultFleetGaugesReadLiveVersion(t *testing.T) {
	srv := newFleetObservation(t)
	version := ""
	srv.hooks.MinProviderVersion = func() string { return version }
	srv.RegisterDefaultGauges()
	if got := srv.Metrics().Snapshot().Gauges["min_provider_version_set"]; got != 0 {
		t.Fatalf("unset version gauge = %v, want 0", got)
	}
	version = "0.9.17"
	makeDecodeProvider(t, srv.registry, "fleet-provider", "M3", "Max", 400, 70, "fleet-model")
	gauges := srv.Metrics().Snapshot().Gauges
	if got := gauges["min_provider_version_set"]; got != 1 {
		t.Errorf("updated version gauge = %v, want 1", got)
	}
	if got := gauges["providers_online"]; got != 1 {
		t.Errorf("provider gauge = %v, want 1", got)
	}
}

func TestDDGaugeLoopEmitsFleetAndExactCacheOnTick(t *testing.T) {
	srv := newFleetObservation(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)
	srv.hooks.MinProviderVersion = func() string { return "0.9.17" }
	emitted := make(chan struct{}, 1)
	srv.hooks.EmitExactCacheDDGauges = func() { emitted <- struct{}{} }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.StartDDGaugeLoop(ctx)
	}()
	defer func() { cancel(); <-done }()
	select {
	case <-emitted:
		t.Fatal("gauge loop emitted before its first tick")
	case <-time.After(20 * time.Millisecond):
	}
	select {
	case <-emitted:
	case <-time.After(30 * time.Second):
		t.Fatal("gauge loop did not call exact-cache hook")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("gauge loop did not stop after cancellation")
	}
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	for _, metric := range []string{
		"providers.online", "attestation.code_attested", "attestation.code_enforced",
		"coordinator.min_provider_version_set", "min_version:0.9.17", "request_queue.depth",
		"utilization.network", "utilization.warm", "utilization.token_budget", "utilization.bottleneck",
		"capacity.tps", "capacity.demand_concurrency", "capacity.serving_capacity", "capacity.spill_arrival_rate",
	} {
		if !hasMetric(packets, metric) {
			t.Errorf("missing %s in gauge tick: %v", metric, packets)
		}
	}
}
