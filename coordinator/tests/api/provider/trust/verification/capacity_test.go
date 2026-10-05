package verification_test

import (
	"context"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/store"
	"sync/atomic"
	"testing"
	"time"
)

func TestMDMSchedulerGlobalConcurrencyCap(t *testing.T) {
	var active atomic.Int32
	var maximum atomic.Int32
	release := make(chan struct{})
	execute := func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		current := active.Add(1)
		for {
			old := maximum.Load()
			if current <= old || maximum.CompareAndSwap(old, current) {
				break
			}
		}
		select {
		case <-release:
		case <-ctx.Done():
		}
		active.Add(-1)
		return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeTransient}
	}
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 12, QueueCapacity: 128, InitialSpreadMax: time.Nanosecond}, mdmSchedulerDeps{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: execute,
	})
	for i := range 64 {
		p := schedulerTestProvider(t, srv, fmt.Sprintf("cap-%d", i), fmt.Sprintf("se-cap-%d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityFirstOrExpired)
		sch.ChallengeSettled(p, false)
	}
	waitSchedulerCondition(t, func() bool { return maximum.Load() == 12 }, "workers did not fill the configured cap")
	if maximum.Load() > 12 {
		t.Fatalf("active attempts reached %d, cap is 12", maximum.Load())
	}
	close(release)
	waitSchedulerCondition(t, func() bool { return active.Load() == 0 }, "attempts did not drain")
}

func TestMDMSchedulerBoundedQueuePrioritizesUnverified(t *testing.T) {
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 3}, mdmSchedulerDeps{})
	for i := range 3 {
		p := schedulerTestProvider(t, srv, fmt.Sprintf("refresh-%d", i), fmt.Sprintf("se-refresh-%d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	}
	high := schedulerTestProvider(t, srv, "first", "se-first")
	sch.Submit(context.Background(), high.ID, high, store.VerificationPriorityFirstOrExpired)
	status := sch.Status()
	if status.Jobs != 3 {
		t.Fatalf("in-memory queue size = %d, want 3", status.Jobs)
	}
	if sch.Candidate(verificationSchedulerKey("se-first", store.VerificationTaskSecurityInfo)) == nil {
		t.Fatal("first/expired work did not evict a redundant refresh")
	}
	persisted, err := st.GetVerificationJob(context.Background(), "se-refresh-0", store.VerificationTaskSecurityInfo)
	if err != nil || persisted == nil {
		t.Fatalf("evicted refresh was not retained durably: %+v, %v", persisted, err)
	}
}

// TestMDMSchedulerReservedUrgentWorkerSlot proves the urgent reservation:
// long-running refresh MDA attempts may fill every general worker slot but
// never the reserved one, and a first/expired SecurityInfo job dispatches
// immediately through the reserved slot while the MDA attempts stay blocked.
func TestMDMSchedulerReservedUrgentWorkerSlot(t *testing.T) {
	releaseMDA := make(chan struct{})
	var mdaActive atomic.Int32
	urgentExecuted := make(chan struct{}, 1)
	execute := func(ctx context.Context, binding mdmLiveBinding, kind store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		if kind == store.VerificationTaskMDA {
			mdaActive.Add(1)
			select {
			case <-releaseMDA:
			case <-ctx.Done():
			}
			mdaActive.Add(-1)
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true, Terminal: true}
		}
		if binding.Attestation.PublicKey == "se-urgent" {
			urgentExecuted <- struct{}{}
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeInvalid, Terminal: true}
		}
		return mdmSchedulerAttemptResult{
			Outcome: store.VerificationOutcomeSuccess, Granted: true, Terminal: true,
			UDID: "udid-" + binding.Attestation.PublicKey,
		}
	}
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 3, QueueCapacity: 16, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		Jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute:  execute,
		ReuseMDA: func(mdmLiveBinding) bool { return false },
	})

	// Three refresh providers: each SecurityInfo grant enqueues a blocked
	// refresh MDA attempt. General capacity is Workers-1 = 2, so at most two
	// MDA attempts may run; further refresh work must stay queued because it
	// can never occupy the reserved urgent slot.
	for i := range 3 {
		p := schedulerTestProvider(t, srv, fmt.Sprintf("routine-%d", i), fmt.Sprintf("se-routine-%d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
		sch.ChallengeSettled(p, false)
	}
	waitSchedulerCondition(t, func() bool { return mdaActive.Load() == 2 }, "refresh MDA attempts did not fill the general worker slots")
	time.Sleep(50 * time.Millisecond)
	if got := mdaActive.Load(); got != 2 {
		t.Fatalf("refresh MDA attempts occupied %d workers, general capacity is 2", got)
	}

	urgent := schedulerTestProvider(t, srv, "urgent", "se-urgent")
	sch.Submit(context.Background(), urgent.ID, urgent, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(urgent, false)
	select {
	case <-urgentExecuted:
	case <-time.After(3 * time.Second):
		t.Fatal("first/expired SecurityInfo never dispatched; refresh work starved the reserved slot")
	}
	if got := mdaActive.Load(); got != 2 {
		t.Fatalf("reserved slot leaked to refresh work while urgent ran: %d MDA attempts active", got)
	}
	close(releaseMDA)
	waitSchedulerCondition(t, func() bool { return mdaActive.Load() == 0 }, "blocked MDA attempts did not drain")
}
