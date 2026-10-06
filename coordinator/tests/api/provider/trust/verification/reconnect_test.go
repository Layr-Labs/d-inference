package verification_test

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"sync/atomic"
	"testing"
	"time"
)

type delayedSettleVerificationStore struct {
	*memory.MemoryStore
	beforeUpsert bool
	pauseUpsert  func(store.VerificationJob)
}

func (s *delayedSettleVerificationStore) UpsertVerificationJob(ctx context.Context, rec store.VerificationJob) (store.VerificationJob, error) {
	if s.beforeUpsert {
		s.pauseUpsert(rec)
	}
	updated, err := s.MemoryStore.UpsertVerificationJob(ctx, rec)
	if err == nil && !s.beforeUpsert {
		s.pauseUpsert(rec)
	}
	return updated, err
}

func TestMDMSchedulerReconnectReleaseBeforeSettleReturns(t *testing.T) {
	for _, beforeUpsert := range []bool{false, true} {
		name := "release_after_upsert"
		if beforeUpsert {
			name = "release_before_upsert"
		}
		t.Run(name, func(t *testing.T) {
			now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
			settlePaused := make(chan struct{})
			returnSettle := make(chan struct{})
			st := &delayedSettleVerificationStore{
				MemoryStore:  memory.NewMemory(store.Config{}),
				beforeUpsert: beforeUpsert,
				pauseUpsert: func(rec store.VerificationJob) {
					if rec.Serial == "serial-replacement" && rec.State == store.VerificationStatePending {
						close(settlePaused)
						select {
						case <-returnSettle:
						case <-t.Context().Done():
						}
					}
				},
			}
			oldStarted := make(chan struct{})
			finishOld := make(chan struct{})
			srv, sch := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
				Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
			}, mdmSchedulerDeps{
				Now:    func() time.Time { return now },
				Jitter: func(minimum, _ time.Duration) time.Duration { return minimum },
				Execute: func(_ context.Context, binding mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
					if binding.ProviderID == "old" {
						close(oldStarted)
						select {
						case <-finishOld:
						case <-t.Context().Done():
						}
					}
					return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeTransient}
				},
			})
			// Drive dispatch explicitly so the released row cannot be claimed again
			// before we inspect whether the delayed settle resurrects its old claim.
			withoutLiveDispatcher(sch)
			sch.StartWorkers()
			old := schedulerTestProvider(t, srv, "old", "se-settle-release")
			sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityRefresh)
			sch.ChallengeSettled(old, false)
			sch.DispatchDueRows()
			select {
			case <-oldStarted:
			case <-time.After(time.Second):
				t.Fatal("old attempt did not start")
			}

			replacement := schedulerTestProvider(t, srv, "replacement", "se-settle-release")
			generation := sch.Submit(context.Background(), replacement.ID, replacement, store.VerificationPriorityRefresh)
			sch.PromoteFailedFastSkip(replacement)
			settled := make(chan struct{})
			go func() {
				defer close(settled)
				sch.ChallengeSettled(replacement, false)
			}()
			select {
			case <-settlePaused:
			case <-time.After(time.Second):
				t.Fatal("replacement settle did not reach the store barrier")
			}
			close(finishOld)
			key := verificationSchedulerKey("se-settle-release", store.VerificationTaskSecurityInfo)
			waitSchedulerCondition(t, func() bool {
				job := sch.Candidate(key)
				return job != nil && !job.Running && job.BindingGen == generation &&
					job.Record.State == store.VerificationStatePending && job.Record.ClaimOwner == ""
			}, "old attempt did not reconcile its released claim")
			close(returnSettle)
			select {
			case <-settled:
			case <-time.After(time.Second):
				t.Fatal("replacement settle did not return")
			}

			rec := sch.Candidate(key).Record
			if rec.State != store.VerificationStatePending || rec.ClaimOwner != "" || !rec.NextAttemptAt.Equal(now) ||
				!IsUrgent(rec) {
				t.Fatalf("delayed settle overwrote the released claim: %+v", rec)
			}
			durable, err := st.GetVerificationJob(context.Background(), "se-settle-release", store.VerificationTaskSecurityInfo)
			if err != nil || durable == nil || durable.Priority != rec.Priority || durable.State != rec.State ||
				!durable.NextAttemptAt.Equal(rec.NextAttemptAt) || durable.ClaimOwner != rec.ClaimOwner {
				t.Fatalf("reconciled record disagrees with durable state: memory=%+v durable=%+v err=%v", rec, durable, err)
			}
			sch.DispatchDueRows()
			waitSchedulerCondition(t, func() bool {
				rec, err := st.GetVerificationJob(context.Background(), "se-settle-release", store.VerificationTaskSecurityInfo)
				return err == nil && rec != nil && rec.State == store.VerificationStateBackoff &&
					rec.RetryStage == 1 && rec.ClaimOwner == "" && rec.NextAttemptAt.Equal(now.Add(mdmRetryFirstMin))
			}, "replacement did not redispatch from the released due time")
		})
	}
}

func TestMDMSchedulerSingleflightAcrossReconnectPreservesDue(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var jitterCalls atomic.Int32
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8, InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute}, mdmSchedulerDeps{
		Now: func() time.Time { return now },
		Jitter: func(time.Duration, time.Duration) time.Duration {
			if jitterCalls.Add(1) == 1 {
				return 7 * time.Minute
			}
			return 19 * time.Minute
		},
	})
	first := schedulerTestProvider(t, srv, "rebind-a", "se-rebind")
	g1 := sch.Submit(context.Background(), first.ID, first, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(first, false)
	rec, _ := sch.store.GetVerificationJob(context.Background(), "se-rebind", store.VerificationTaskSecurityInfo)
	originalDue := rec.NextAttemptAt
	second := schedulerTestProvider(t, srv, "rebind-b", "se-rebind")
	g2 := sch.Submit(context.Background(), second.ID, second, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(second, false)
	rec, _ = sch.store.GetVerificationJob(context.Background(), "se-rebind", store.VerificationTaskSecurityInfo)
	if g2 <= g1 || !rec.NextAttemptAt.Equal(originalDue) {
		t.Fatalf("rebind generation/due = %d/%s, want >%d/%s", g2, rec.NextAttemptAt, g1, originalDue)
	}
	jobs := sch.Status().Jobs
	boundProvider := sch.Candidate(verificationSchedulerKey("se-rebind", store.VerificationTaskSecurityInfo)).Binding.Provider
	if jobs != 1 || boundProvider != second {
		t.Fatalf("singleflight jobs=%d current_binding=%v", jobs, boundProvider == second)
	}
}

func TestMDMSchedulerReconnectDuringInflightRefreshesReleasedClaim(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	started := make(chan struct{}, 1)
	finishOld := make(chan struct{})
	execute := func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		// Only the first start is observed. A rebound attempt must never
		// block on this test notification or prevent Close from cancelling it.
		select {
		case started <- struct{}{}:
		default:
		}
		select {
		case <-finishOld:
			return mdmSchedulerAttemptResult{
				Outcome: store.VerificationOutcomeTransient,
			}
		case <-ctx.Done():
			return mdmSchedulerAttemptResult{
				Outcome: store.VerificationOutcomeCancelled,
			}
		}
	}
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, mdmSchedulerDeps{
		Now: func() time.Time { return now },
		Jitter: func(minimum, _ time.Duration) time.Duration {
			if minimum >= mdmRetryFirstMin {
				return minimum
			}
			return 0
		},
		Execute: execute,
	})
	old := schedulerTestProvider(t, srv, "old-generation", "se-inflight")
	sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(old, false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("old attempt did not start")
	}
	newProvider := schedulerTestProvider(t, srv, "new-generation", "se-inflight")
	newGeneration := sch.Submit(context.Background(), newProvider.ID, newProvider, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(newProvider, false)
	close(finishOld)
	waitSchedulerCondition(t, func() bool {
		rec, err := st.GetVerificationJob(
			context.Background(), "se-inflight", store.VerificationTaskSecurityInfo,
		)
		return err == nil && rec != nil &&
			rec.State == store.VerificationStateBackoff &&
			rec.RetryStage == 1 && rec.ClaimOwner == ""
	}, "rebound job was not refreshed and redispatched from its persisted due time")
	job := sch.Candidate(verificationSchedulerKey("se-inflight", store.VerificationTaskSecurityInfo))
	inMemoryCurrent := job != nil && job.BindingGen == newGeneration &&
		job.Record.State == store.VerificationStateBackoff &&
		job.Record.RetryStage == 1 && job.Record.ClaimOwner == ""
	if !inMemoryCurrent {
		t.Fatal("rebound in-memory job did not adopt authoritative backoff state")
	}
	rec, err := st.GetVerificationJob(context.Background(), "se-inflight", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State != store.VerificationStateBackoff ||
		rec.RetryStage != 1 || !rec.NextAttemptAt.Equal(now.Add(mdmRetryFirstMin)) {
		t.Fatalf("authoritative rebound state = %+v, err=%v", rec, err)
	}
}
