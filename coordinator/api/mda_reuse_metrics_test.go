package api

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestMDAReuseCountsOnceOnEachSink pins the one-event-one-sample rule for the
// cached-proof shortcut, which is the only mda.verification outcome recorded by
// the function the scheduler calls rather than by the scheduler itself.
// attachCachedMDAProof counts its own reuse, so a caller that also counted it
// turned one reuse into two — which is what this branch fixed, and what a future
// edit to either side would silently reintroduce.
//
// It asserts the magnitude, not just the presence: the Datadog client aggregates
// a counter per (name, tag set) inside a flush window, so a double count arrives
// as `...:2|c|` on a single packet and a presence check would not see it.
func TestMDAReuseCountsOnceOnEachSink(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	now := time.Date(2026, 9, 16, 12, 0, 0, 0, time.UTC)
	// Declared ahead of the harness because the reuseMDA stub records through the
	// server it is being installed into.
	var srv *Server
	var sch *mdmVerificationScheduler
	srv, sch = newSchedulerTestServerWithStore(t, store.NewMemory(store.Config{}), MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		now:    func() time.Time { return now },
		jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		// Stands in for attachCachedMDAProof, including the part that matters here:
		// the reuse path owns the count.
		reuseMDA: func(binding mdmLiveBinding) bool {
			srv.metrics().Trust.MDAVerification.Inc("reused")
			return true
		},
		execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeSuccess, granted: true}
		},
	})
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	provider := schedulerTestProvider(t, srv, "mda-reuse", "se-mda-reuse")
	sch.Submit(context.Background(), provider.ID, provider, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(provider, false)

	mirrorKey := counterKey("mda_verification_total", MetricLabel{"outcome", "reused"})
	waitSchedulerCondition(t, func() bool {
		return srv.adminMetrics.Snapshot().Counters[mirrorKey] >= 1
	}, "the reuse path never reached the in-process registry")

	if got := srv.adminMetrics.Snapshot().Counters[mirrorKey]; got != 1 {
		t.Errorf("mda_verification_total{outcome:reused} = %d, want 1: one reuse is one event", got)
	}

	_ = dd.Statsd.Flush()
	var reused []string
	for _, p := range collector.drain() {
		if strings.Contains(p, "mda.verification") && strings.Contains(p, "outcome:reused") {
			reused = append(reused, p)
		}
	}
	if len(reused) != 1 {
		t.Fatalf("mda.verification{outcome:reused} produced %d packets, want 1: %v", len(reused), reused)
	}
	if !strings.Contains(reused[0], "mda.verification:1|c|") {
		t.Errorf("mda.verification{outcome:reused} = %q, want a single increment", reused[0])
	}
}
