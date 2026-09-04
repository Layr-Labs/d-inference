package api

import (
	"testing"
	"time"
)

// TestProviderProfileMetricCountsSampledOutRows: profiler.provider_profile
// {valid,reason} is emitted for every decoded provider profile — the
// sampled-out clean successes the sink discards before flattening as well as
// the persisted rows — so the valid/invalid ratio the series exists for is
// not skewed by sampling (invalid profiles are always force-recorded, valid
// ones on clean successes were ~90% sampled out). Before the change only
// applyProviderProfile (persisted rows) emitted it: the sampled-out valid
// profile below produced no packet.
func TestProviderProfileMetricCountsSampledOutRows(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	srv := newProfilerTestServer(t)
	srv.SetDatadog(dd)
	srv.profiler.sampleRate = 0
	sink := srv.profiler.sink

	// Sampled out: a clean success carrying a valid provider profile.
	rp, ap := cleanSuccessProfile("coord-" + newRequestID())
	rp.T0 = fixtureReceivedAt
	ap.SetProviderProfileRaw(fixtureProfile(t, "inference_complete_full"))
	if !sink.submit(rp, ap) {
		t.Fatal("submit dropped the sampled-out job")
	}
	if !waitForCond(5*time.Second, func() bool { return sink.sampledOut.Load() == 1 }) {
		t.Fatalf("sampledOut = %d, want 1", sink.sampledOut.Load())
	}
	// Persisted: an invalid profile is force-recorded and counted by the
	// flatten path, as before.
	rp2, ap2 := cleanSuccessProfile("coord-" + newRequestID())
	ap2.SetProviderProfileRaw([]byte(`{"schema":`))
	if !sink.submit(rp2, ap2) {
		t.Fatal("submit dropped the invalid-profile job")
	}
	if !waitForCond(5*time.Second, func() bool { return sink.built.Load() == 1 }) {
		t.Fatalf("built = %d, want 1", sink.built.Load())
	}

	packets := drainUntil(t, statsdFlusher{dd.Statsd}, collector, 5*time.Second, func(ps []string) bool {
		return hasMetricWith(ps, "profiler.provider_profile", "valid:true", "reason:none") &&
			hasMetricWith(ps, "profiler.provider_profile", "valid:false")
	})
	if !hasMetricWith(packets, "profiler.provider_profile", "valid:true", "reason:none") {
		t.Fatalf("sampled-out valid profile emitted no profiler.provider_profile{valid:true,reason:none}; packets=%v", packets)
	}
	if !hasMetricWith(packets, "profiler.provider_profile", "valid:false") {
		t.Fatalf("persisted invalid profile emitted no profiler.provider_profile{valid:false}; packets=%v", packets)
	}
}
