package verification_test

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"testing"
	"time"
)

func TestMDMSchedulerCrossInstanceOldCompletionReopensCurrentBinding(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	st := memory.NewMemory(store.Config{})
	oldStarted := make(chan struct{}, 1)
	finishOld := make(chan struct{})
	srvOld, oldScheduler := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		Now: func() time.Time { return now },
		Jitter: func(time.Duration, time.Duration) time.Duration {
			return 0
		},
		ReuseMDA: func(mdmLiveBinding) bool { return true },
		Execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			oldStarted <- struct{}{}
			select {
			case <-finishOld:
				return mdmSchedulerAttemptResult{
					Outcome: store.VerificationOutcomeSuccess,
					Granted: true,
				}
			case <-ctx.Done():
				return mdmSchedulerAttemptResult{
					Outcome: store.VerificationOutcomeCancelled,
				}
			}
		},
	})
	oldProvider := schedulerTestProvider(t, srvOld, "cross-old", "se-cross")
	oldScheduler.Submit(context.Background(), oldProvider.ID, oldProvider, store.VerificationPriorityRecovery)
	oldScheduler.ChallengeSettled(oldProvider, false)
	select {
	case <-oldStarted:
	case <-time.After(time.Second):
		t.Fatal("old coordinator did not claim work")
	}

	currentStarted := make(chan struct{}, 1)
	srvCurrent, currentScheduler := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		Now: func() time.Time { return now },
		Jitter: func(time.Duration, time.Duration) time.Duration {
			return 0
		},
		Execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			currentStarted <- struct{}{}
			return mdmSchedulerAttemptResult{
				Outcome: store.VerificationOutcomeInvalid, Terminal: true,
			}
		},
	})
	currentProvider := schedulerTestProvider(t, srvCurrent, "cross-current", "se-cross")
	currentScheduler.Submit(
		context.Background(), currentProvider.ID, currentProvider,
		store.VerificationPriorityRecovery,
	)
	currentScheduler.ChallengeSettled(currentProvider, false)
	marked, err := st.GetVerificationJob(
		context.Background(), "se-cross", store.VerificationTaskSecurityInfo,
	)
	if err != nil || marked == nil || marked.State != store.VerificationStateRunning ||
		!marked.ReopenPending {
		t.Fatalf("replacement challenge did not mark running row for reopen: %+v, err=%v", marked, err)
	}

	close(finishOld)
	if currentProvider.GetTrustLevel() != registry.TrustSelfSigned {
		t.Fatal("current binding inherited old coordinator live trust")
	}
	select {
	case <-currentStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("current binding was not dispatched after old completion reopened the durable row")
	}
	waitSchedulerCondition(t, func() bool {
		rec, getErr := st.GetVerificationJob(
			context.Background(), "se-cross", store.VerificationTaskSecurityInfo,
		)
		return getErr == nil && rec != nil &&
			rec.State == store.VerificationStateCompleted &&
			rec.LastOutcome == store.VerificationOutcomeInvalid
	}, "current-generation result did not complete its reopened row")
}

func TestMDMSchedulerOldCompletionBeforeReplacementChallengeReopensCurrentBinding(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	st := memory.NewMemory(store.Config{})
	oldStarted := make(chan struct{}, 1)
	finishOld := make(chan struct{})
	srvOld, oldScheduler := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		Now:      func() time.Time { return now },
		Jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		ReuseMDA: func(mdmLiveBinding) bool { return true },
		Execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			oldStarted <- struct{}{}
			select {
			case <-finishOld:
				return mdmSchedulerAttemptResult{
					Outcome: store.VerificationOutcomeSuccess,
					Granted: true,
				}
			case <-ctx.Done():
				return mdmSchedulerAttemptResult{
					Outcome: store.VerificationOutcomeCancelled,
				}
			}
		},
	})
	oldProvider := schedulerTestProvider(
		t, srvOld, "cross-before-challenge-old",
		"se-cross-before-challenge",
	)
	oldScheduler.Submit(
		context.Background(), oldProvider.ID, oldProvider,
		store.VerificationPriorityRecovery,
	)
	oldScheduler.ChallengeSettled(oldProvider, false)
	select {
	case <-oldStarted:
	case <-time.After(time.Second):
		t.Fatal("old coordinator did not claim work")
	}

	currentStarted := make(chan struct{}, 1)
	srvCurrent, currentScheduler := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		Now:    func() time.Time { return now },
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			currentStarted <- struct{}{}
			return mdmSchedulerAttemptResult{
				Outcome:  store.VerificationOutcomeInvalid,
				Terminal: true,
			}
		},
	})
	currentProvider := schedulerTestProvider(
		t, srvCurrent, "cross-before-challenge-current",
		"se-cross-before-challenge",
	)
	currentScheduler.Submit(
		context.Background(), currentProvider.ID, currentProvider,
		store.VerificationPriorityRecovery,
	)
	close(finishOld)
	waitSchedulerCondition(t, func() bool {
		rec, err := st.GetVerificationJob(
			context.Background(), "se-cross-before-challenge",
			store.VerificationTaskSecurityInfo,
		)
		return err == nil && rec != nil &&
			rec.State == store.VerificationStateCompleted
	}, "old coordinator did not complete before replacement challenge")

	currentScheduler.ChallengeSettled(currentProvider, false)
	select {
	case <-currentStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("replacement challenge did not reopen completed old work")
	}
	if currentProvider.GetTrustLevel() != registry.TrustSelfSigned {
		t.Fatal("replacement inherited old coordinator live trust")
	}
}
