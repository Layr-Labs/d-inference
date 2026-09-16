package mdmscheduler

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerRetiredWorkerCannotReleaseReplacementClaim(t *testing.T) {
	srv, st, sch := newSchedulerHarness(t, Config{Workers: 2, QueueCapacity: 8}, Dependencies{
		Jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		ReuseMDA: func(Target) bool { return true },
	})
	withoutLiveDispatcher(sch)
	const seKey = "se-retired-worker"
	key := jobKey(seKey, store.VerificationTaskSecurityInfo)
	claim := func() workItem {
		t.Helper()
		sch.claimAndDispatch(key, time.Now().UTC())
		select {
		case work := <-sch.work:
			t.Cleanup(func() { work.stopAfter(); work.cancel() })
			return work
		case <-time.After(time.Second):
			t.Fatal("verification job was not claimed")
			return workItem{}
		}
	}
	old := schedulerProvider(t, srv, "retired-worker-old", seKey)
	sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(old, false)
	oldWork := claim()
	sch.ObserveAttemptUDID(old, "udid-retired-worker")
	sch.ObserveAttemptCommand(old, store.VerificationTaskSecurityInfo, "udid-retired-worker", "command-old-worker")
	// The callback completes the durable row and cancels its worker. The
	// worker can still be unwinding when a reconnect claims new verification.
	sch.CompleteLateSecurityInfo(oldWork.binding, "udid-retired-worker", "command-old-worker")
	if oldWork.ctx.Err() == nil {
		t.Fatal("late completion did not cancel its old worker")
	}
	replacement := schedulerProvider(t, srv, "retired-worker-new", seKey)
	generation := sch.Submit(context.Background(), replacement.ID, replacement, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(replacement, false)
	newWork := claim()
	sch.finishAttempt(oldWork, AttemptResult{Outcome: store.VerificationOutcomeCancelled})

	rec, err := st.GetVerificationJob(context.Background(), seKey, store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State != store.VerificationStateRunning || rec.ClaimOwner != newWork.job.ClaimOwner {
		t.Fatalf("retired worker released the replacement claim: %+v, %v", rec, err)
	}
	sch.mu.Lock()
	job := sch.jobs[key]
	current := job != nil && job.running && job.attemptCancel != nil && job.bindingGen == generation
	sch.mu.Unlock()
	if !current {
		t.Fatal("retired worker cleared the replacement attempt's live state")
	}
	sch.Unbind(seKey, generation)
	if newWork.ctx.Err() == nil {
		t.Fatal("replacement disconnect lost its attempt cancellation")
	}
	sch.finishAttempt(newWork, AttemptResult{Outcome: store.VerificationOutcomeCancelled})
}

type pausedVerificationSettlementStore struct {
	*store.MemoryStore
	complete bool
	after    bool
	entered  chan struct{}
	release  chan struct{}
	once     sync.Once
}

func (s *pausedVerificationSettlementStore) pause(ctx context.Context) {
	first := false
	s.once.Do(func() { first = true })
	if first {
		close(s.entered)
		select {
		case <-s.release:
		case <-ctx.Done():
		}
	}
}

func (s *pausedVerificationSettlementStore) CompleteVerificationJob(ctx context.Context, key string, kind store.VerificationTaskKind, owner string, outcome store.VerificationOutcome, now time.Time) error {
	if s.complete && !s.after {
		s.pause(ctx)
	}
	err := s.MemoryStore.CompleteVerificationJob(ctx, key, kind, owner, outcome, now)
	if s.complete && s.after {
		s.pause(ctx)
	}
	return err
}

func (s *pausedVerificationSettlementStore) RescheduleVerificationJob(ctx context.Context, key string, kind store.VerificationTaskKind, owner string, priority store.VerificationPriority, stage int, delay time.Duration, next time.Time, outcome store.VerificationOutcome, now time.Time) error {
	if !s.complete && !s.after {
		s.pause(ctx)
	}
	err := s.MemoryStore.RescheduleVerificationJob(ctx, key, kind, owner, priority, stage, delay, next, outcome, now)
	if !s.complete && s.after {
		s.pause(ctx)
	}
	return err
}

func TestMDMSchedulerSettlementKeepsReboundVerification(t *testing.T) {
	for _, tc := range []struct {
		name     string
		complete bool
		after    bool
		late     bool
	}{
		{name: "before_completion", complete: true},
		{name: "after_completion", complete: true, after: true},
		{name: "before_reschedule"},
		{name: "after_reschedule", after: true},
		{name: "late_callback_before_completion", complete: true, late: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := &pausedVerificationSettlementStore{MemoryStore: store.NewMemory(store.Config{}), complete: tc.complete, after: tc.after, entered: make(chan struct{}), release: make(chan struct{})}
			var releaseOnce sync.Once
			unblock := func() { releaseOnce.Do(func() { close(st.release) }) }
			t.Cleanup(unblock)
			srv, sch := newSchedulerHarnessWithStore(t, st, Config{Workers: 1, QueueCapacity: 8}, Dependencies{
				Jitter:   func(minimum, _ time.Duration) time.Duration { return minimum },
				ReuseMDA: func(Target) bool { return true },
			})
			withoutLiveDispatcher(sch)
			const seKey = "se-settling-worker"
			key := jobKey(seKey, store.VerificationTaskSecurityInfo)
			old := schedulerProvider(t, srv, "settling-old", seKey)
			sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityFirstOrExpired)
			sch.ChallengeSettled(old, false)
			sch.claimAndDispatch(key, time.Now().UTC())
			var work workItem
			select {
			case work = <-sch.work:
			case <-time.After(time.Second):
				t.Fatal("initial verification was not claimed")
			}
			t.Cleanup(func() { work.stopAfter(); work.cancel() })
			if tc.late {
				sch.ObserveAttemptUDID(old, "udid-settling-worker")
				sch.ObserveAttemptCommand(old, store.VerificationTaskSecurityInfo, "udid-settling-worker", "command-settling-worker")
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				sch.finishAttempt(work, AttemptResult{Outcome: store.VerificationOutcomeTransient, Terminal: tc.complete})
			}()
			t.Cleanup(func() { unblock(); <-done })
			select {
			case <-st.entered:
			case <-time.After(time.Second):
				t.Fatal("settlement did not reach its store barrier")
			}
			if tc.late {
				sch.CompleteLateSecurityInfo(work.binding, "udid-settling-worker", "command-settling-worker")
			}
			replacement := schedulerProvider(t, srv, "settling-replacement", seKey)
			generation := sch.Submit(context.Background(), replacement.ID, replacement, store.VerificationPriorityFirstOrExpired)
			sch.ChallengeSettled(replacement, false)
			unblock()
			<-done

			rec, err := st.GetVerificationJob(context.Background(), seKey, store.VerificationTaskSecurityInfo)
			want := store.VerificationStatePending
			if !tc.complete && tc.after {
				want = store.VerificationStateBackoff
			}
			if err != nil || rec == nil || rec.State != want || rec.ClaimOwner != "" {
				t.Fatalf("replacement durable state = %+v, %v; want %s", rec, err, want)
			}
			sch.mu.Lock()
			job := sch.jobs[key]
			binding := sch.bindings[seKey]
			current := job != nil && !job.running && job.bindingGen == generation && job.record.State == rec.State && job.record.NextAttemptAt.Equal(rec.NextAttemptAt) && job.record.ClaimOwner == "" && binding != nil && binding.generation == generation
			sch.mu.Unlock()
			if !current {
				t.Fatal("settled old worker did not retain and refresh the rebound verification")
			}
		})
	}
}

type pausedVerificationReadStore struct {
	*store.MemoryStore
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (s *pausedVerificationReadStore) GetVerificationJob(ctx context.Context, key string, kind store.VerificationTaskKind) (*store.VerificationJob, error) {
	rec, err := s.MemoryStore.GetVerificationJob(ctx, key, kind)
	first := false
	s.once.Do(func() { first = true })
	if first {
		close(s.entered)
		select {
		case <-s.release:
		case <-ctx.Done():
		}
	}
	return rec, err
}

func TestMDMSchedulerReboundReadCannotOverwriteNewerSettlement(t *testing.T) {
	st := &pausedVerificationReadStore{MemoryStore: store.NewMemory(store.Config{}), entered: make(chan struct{}), release: make(chan struct{})}
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(st.release) }) }
	t.Cleanup(unblock)
	srv, sch := newSchedulerHarnessWithStore(t, st, Config{Workers: 2, QueueCapacity: 8}, Dependencies{
		Jitter: func(minimum, _ time.Duration) time.Duration { return minimum },
	})
	withoutLiveDispatcher(sch)
	const seKey = "se-rebound-read"
	key := jobKey(seKey, store.VerificationTaskSecurityInfo)
	claim := func() workItem {
		t.Helper()
		sch.claimAndDispatch(key, time.Now().UTC())
		select {
		case work := <-sch.work:
			t.Cleanup(func() { work.stopAfter(); work.cancel() })
			return work
		case <-time.After(time.Second):
			t.Fatal("verification was not claimed")
			return workItem{}
		}
	}
	old := schedulerProvider(t, srv, "rebound-read-old", seKey)
	sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(old, false)
	oldWork := claim()
	replacement := schedulerProvider(t, srv, "rebound-read-new", seKey)
	generation := sch.Submit(context.Background(), replacement.ID, replacement, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(replacement, false)
	done := make(chan struct{})
	go func() {
		defer close(done)
		sch.finishAttempt(oldWork, AttemptResult{Outcome: store.VerificationOutcomeCancelled})
	}()
	t.Cleanup(func() { unblock(); <-done })
	select {
	case <-st.entered:
	case <-time.After(time.Second):
		t.Fatal("rebound reconciliation did not reach its read barrier")
	}
	newWork := claim()
	sch.finishAttempt(newWork, AttemptResult{Outcome: store.VerificationOutcomeTransient})
	unblock()
	<-done

	rec, err := st.GetVerificationJob(context.Background(), seKey, store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State != store.VerificationStateBackoff || rec.RetryStage != 1 {
		t.Fatalf("replacement retry did not settle: %+v, %v", rec, err)
	}
	sch.mu.Lock()
	job := sch.jobs[key]
	current := job != nil && job.bindingGen == generation && job.record.State == rec.State && job.record.RetryStage == rec.RetryStage && job.record.NextAttemptAt.Equal(rec.NextAttemptAt)
	sch.mu.Unlock()
	if !current {
		t.Fatal("old reconciliation read overwrote the replacement's settled retry")
	}
}
