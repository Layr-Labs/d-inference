package mdmscheduler

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerSingleflightAcrossReconnectPreservesDue(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var jitterCalls atomic.Int32
	srv, _, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 8, InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute}, Dependencies{
		Now: func() time.Time { return now },
		Jitter: func(time.Duration, time.Duration) time.Duration {
			if jitterCalls.Add(1) == 1 {
				return 7 * time.Minute
			}
			return 19 * time.Minute
		},
	})
	first := schedulerProvider(t, srv, "rebind-a", "se-rebind")
	g1 := sch.Submit(context.Background(), first.ID, first, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(first, false)
	rec, _ := sch.store.GetVerificationJob(context.Background(), "se-rebind", store.VerificationTaskSecurityInfo)
	originalDue := rec.NextAttemptAt
	second := schedulerProvider(t, srv, "rebind-b", "se-rebind")
	g2 := sch.Submit(context.Background(), second.ID, second, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(second, false)
	rec, _ = sch.store.GetVerificationJob(context.Background(), "se-rebind", store.VerificationTaskSecurityInfo)
	if g2 <= g1 || !rec.NextAttemptAt.Equal(originalDue) {
		t.Fatalf("rebind generation/due = %d/%s, want >%d/%s", g2, rec.NextAttemptAt, g1, originalDue)
	}
	sch.mu.Lock()
	jobs := len(sch.jobs)
	boundProvider := sch.bindings["se-rebind"].provider
	sch.mu.Unlock()
	if jobs != 1 || boundProvider != second {
		t.Fatalf("singleflight jobs=%d current_binding=%v", jobs, boundProvider == second)
	}
}

func TestMDMSchedulerDisconnectCancelsQueuedAndRunning(t *testing.T) {
	started := make(chan struct{}, 1)
	cancelled := make(chan struct{}, 1)
	execute := func(ctx context.Context, _ Target, _ store.VerificationTaskKind, _ string) AttemptResult {
		started <- struct{}{}
		<-ctx.Done()
		cancelled <- struct{}{}
		return AttemptResult{Outcome: store.VerificationOutcomeCancelled}
	}
	srv, st, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, Dependencies{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: execute,
	})
	p := schedulerProvider(t, srv, "disconnect", "se-disconnect")
	g := sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(p, false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("attempt did not start")
	}
	sch.Unbind("se-disconnect", g)
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("running attempt was not cancelled")
	}
	waitSchedulerCondition(t, func() bool { sch.mu.Lock(); defer sch.mu.Unlock(); return len(sch.jobs) == 0 }, "disconnected job remained in memory")
	rec, err := st.GetVerificationJob(context.Background(), "se-disconnect", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State == store.VerificationStateCompleted {
		t.Fatalf("disconnect discarded durable retry state: %+v, %v", rec, err)
	}
}

func TestMDMSchedulerFastSkipCancelsBeforeCommand(t *testing.T) {
	var attempts atomic.Int32
	srv, st, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 8}, Dependencies{
		Execute: func(context.Context, Target, store.VerificationTaskKind, string) AttemptResult {
			attempts.Add(1)
			return AttemptResult{}
		},
	})
	p := schedulerProvider(t, srv, "fast", "se-fast")
	sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	sch.ChallengeSettled(p, true)
	time.Sleep(10 * time.Millisecond)
	if attempts.Load() != 0 {
		t.Fatalf("fast skip sent %d commands", attempts.Load())
	}
	rec, err := st.GetVerificationJob(context.Background(), "se-fast", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State != store.VerificationStateCompleted || rec.LastOutcome != store.VerificationOutcomeReused {
		t.Fatalf("fast skip durable state = %+v, %v", rec, err)
	}
}

func TestMDMSchedulerGenerationChurnRetainsNoSEKeys(t *testing.T) {
	srv, _, sch := newSchedulerHarness(t, Config{
		Workers: 1, QueueCapacity: 1,
	}, Dependencies{})
	const churn = 2000
	for i := range churn {
		seKey := fmt.Sprintf("se-churn-%d", i)
		provider := schedulerProvider(t, srv, fmt.Sprintf("churn-%d", i), seKey)
		generation := sch.Submit(
			context.Background(), provider.ID, provider,
			store.VerificationPriorityRefresh,
		)
		sch.Unbind(seKey, generation)
	}
	sch.mu.Lock()
	jobs := len(sch.jobs)
	bindings := len(sch.bindings)
	udids := len(sch.byUDID)
	sch.mu.Unlock()
	if jobs != 0 || bindings != 0 || udids != 0 {
		t.Fatalf("scheduler retained per-SE churn state: jobs=%d bindings=%d udids=%d", jobs, bindings, udids)
	}
	if generation := sch.generation.Load(); generation != churn {
		t.Fatalf("global generation = %d, want %d", generation, churn)
	}
}
