package trust

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
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
				now:    func() time.Time { return now },
				jitter: func(minimum, _ time.Duration) time.Duration { return minimum },
				execute: func(_ context.Context, binding mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
					if binding.providerID == "old" {
						close(oldStarted)
						select {
						case <-finishOld:
						case <-t.Context().Done():
						}
					}
					return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeTransient}
				},
			})
			// Drive dispatch explicitly so the released row cannot be claimed again
			// before we inspect whether the delayed settle resurrects its old claim.
			withoutLiveDispatcher(sch)
			sch.wg.Add(1)
			go sch.worker()
			old := schedulerTestProvider(t, srv, "old", "se-settle-release")
			sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityRefresh)
			sch.ChallengeSettled(old, false)
			sch.dispatchDueRows()
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
				sch.mu.Lock()
				defer sch.mu.Unlock()
				job := sch.jobs[key]
				return job != nil && !job.running && job.bindingGen == generation &&
					job.record.State == store.VerificationStatePending && job.record.ClaimOwner == ""
			}, "old attempt did not reconcile its released claim")
			close(returnSettle)
			select {
			case <-settled:
			case <-time.After(time.Second):
				t.Fatal("replacement settle did not return")
			}

			sch.mu.Lock()
			rec := sch.jobs[key].record
			sch.mu.Unlock()
			if rec.State != store.VerificationStatePending || rec.ClaimOwner != "" || !rec.NextAttemptAt.Equal(now) ||
				!isUrgentVerification(rec) {
				t.Fatalf("delayed settle overwrote the released claim: %+v", rec)
			}
			durable, err := st.GetVerificationJob(context.Background(), "se-settle-release", store.VerificationTaskSecurityInfo)
			if err != nil || durable == nil || durable.Priority != rec.Priority || durable.State != rec.State ||
				!durable.NextAttemptAt.Equal(rec.NextAttemptAt) || durable.ClaimOwner != rec.ClaimOwner {
				t.Fatalf("reconciled record disagrees with durable state: memory=%+v durable=%+v err=%v", rec, durable, err)
			}
			sch.dispatchDueRows()
			waitSchedulerCondition(t, func() bool {
				rec, err := st.GetVerificationJob(context.Background(), "se-settle-release", store.VerificationTaskSecurityInfo)
				return err == nil && rec != nil && rec.State == store.VerificationStateBackoff &&
					rec.RetryStage == 1 && rec.ClaimOwner == "" && rec.NextAttemptAt.Equal(now.Add(mdmRetryFirstMin))
			}, "replacement did not redispatch from the released due time")
		})
	}
}
