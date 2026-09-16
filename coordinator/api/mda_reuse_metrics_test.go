package api

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// One reuse event is one Datadog sample and one in-process increment.
//
// The cached-proof shortcut is the only mda.verification outcome recorded by the
// function the scheduler calls (attachCachedMDAProof) rather than by the
// scheduler itself, so both of the scheduler's reuseMDA call sites are a place
// where the same event can be counted a second time — which is what this branch
// fixed, and what an edit to either side would silently reintroduce. There is one
// test per call site: the executor's completion path and the late-SecurityInfo
// callback.
//
// Both assert the magnitude, not just the presence. The Datadog client aggregates
// a counter per (name, tag set) inside a flush window, so a double count arrives
// as `...:2|c|` on a single packet that a presence check would happily accept.

// TestMDAReuseCountsOnceFromSchedulerCompletion drives the executor's granted +
// terminal path, which calls reuseMDA after completing the SecurityInfo job.
func TestMDAReuseCountsOnceFromSchedulerCompletion(t *testing.T) {
	now := time.Date(2026, 9, 16, 12, 0, 0, 0, time.UTC)
	// Declared ahead of the harness because the reuseMDA stub records through the
	// server it is being installed into.
	var srv *Server
	var sch *mdmVerificationScheduler
	srv, sch = newSchedulerTestServerWithStore(t, store.NewMemory(store.Config{}), MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		now:      func() time.Time { return now },
		jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		reuseMDA: reuseMDAStub(&srv),
		execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeSuccess, granted: true}
		},
	})
	collector, flusher := attachTestDD(t, srv)

	provider := schedulerTestProvider(t, srv, "mda-reuse", "se-mda-reuse")
	sch.Submit(context.Background(), provider.ID, provider, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(provider, false)

	assertOneReuseSample(t, srv, collector, flusher)
}

// TestMDAReuseCountsOnceFromLateSecurityInfo drives CompleteLateSecurityInfo, the
// other reuseMDA call site: a SecurityInfo response that arrived after the sync
// wait gave up. Nothing here goes through the executor — the dispatcher is
// disabled — so a count that appears twice can only have come from this path.
func TestMDAReuseCountsOnceFromLateSecurityInfo(t *testing.T) {
	const udid, commandUUID = "UDID-late-reuse", "command-late-reuse"
	now := time.Date(2026, 9, 16, 12, 0, 0, 0, time.UTC)
	var srv *Server
	var sch *mdmVerificationScheduler
	srv, sch = newSchedulerTestServerWithStore(t, store.NewMemory(store.Config{}), MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		now:      func() time.Time { return now },
		jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		reuseMDA: reuseMDAStub(&srv),
		execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			t.Error("the executor ran: this test must exercise the late-SecurityInfo path alone")
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeCancelled}
		},
	})
	withoutLiveDispatcher(sch)
	collector, flusher := attachTestDD(t, srv)

	const seKey = "se-mda-reuse-late"
	provider := schedulerTestProvider(t, srv, "mda-reuse-late", seKey)
	generation := sch.Submit(context.Background(), provider.ID, provider, store.VerificationPriorityRecovery)
	if generation == 0 {
		t.Fatal("scheduler binding was not created")
	}
	sch.ChallengeSettled(provider, false)

	// The callback ownership the real flow establishes when it pushes the
	// SecurityInfo command, as bindLateSecurityInfoForTest does.
	key := verificationSchedulerKey(seKey, store.VerificationTaskSecurityInfo)
	sch.mu.Lock()
	job := sch.jobs[key]
	live := sch.bindings[seKey]
	if job == nil || live == nil {
		sch.mu.Unlock()
		t.Fatal("scheduler did not retain the job and its binding")
	}
	job.record.UDID = udid
	job.callbackGen = generation
	job.callbackUUID = commandUUID
	sch.byUDID[udid] = key
	binding := *live
	sch.mu.Unlock()

	sch.CompleteLateSecurityInfo(binding, udid, commandUUID)

	assertOneReuseSample(t, srv, collector, flusher)
}

// reuseMDAStub stands in for attachCachedMDAProof, including the part that
// matters here: the reuse path owns the count. It takes the server by pointer
// because the harness that installs it is also what constructs the server.
func reuseMDAStub(srv **Server) func(mdmLiveBinding) bool {
	return func(mdmLiveBinding) bool {
		(*srv).metrics().Trust.MDAVerification.Inc("reused")
		return true
	}
}

func assertOneReuseSample(t *testing.T, srv *Server, collector *udpCollector, flusher *datadogFlusher) {
	t.Helper()
	mirrorKey := counterKey("mda_verification_total", MetricLabel{"outcome", "reused"})
	waitSchedulerCondition(t, func() bool {
		return srv.adminMetrics.Snapshot().Counters[mirrorKey] >= 1
	}, "the reuse path never reached the in-process registry")

	if got := srv.adminMetrics.Snapshot().Counters[mirrorKey]; got != 1 {
		t.Errorf("mda_verification_total{outcome:reused} = %d, want 1: one reuse is one event", got)
	}

	var reused []string
	for _, p := range flusher.packets(collector) {
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
