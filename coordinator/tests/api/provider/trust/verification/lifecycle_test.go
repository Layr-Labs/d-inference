package verification_test

import (
	"context"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"sync/atomic"
	"testing"
	"time"
)

func TestMDMSchedulerDisconnectCancelsQueuedAndRunning(t *testing.T) {
	started := make(chan struct{}, 1)
	cancelled := make(chan struct{}, 1)
	execute := func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		started <- struct{}{}
		<-ctx.Done()
		cancelled <- struct{}{}
		return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeCancelled}
	}
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, mdmSchedulerDeps{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: execute,
	})
	p := schedulerTestProvider(t, srv, "disconnect", "se-disconnect")
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
	waitSchedulerCondition(t, func() bool { return sch.Status().Jobs == 0 }, "disconnected job remained in memory")
	rec, err := st.GetVerificationJob(context.Background(), "se-disconnect", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State == store.VerificationStateCompleted {
		t.Fatalf("disconnect discarded durable retry state: %+v, %v", rec, err)
	}
}

func TestMDMSchedulerWorkerPersistsResultsBeforeCancellingAttempt(t *testing.T) {
	tests := []struct {
		name    string
		result  mdmSchedulerAttemptResult
		state   store.VerificationTaskState
		Outcome store.VerificationOutcome
		stage   int
	}{
		{
			name: "success",
			result: mdmSchedulerAttemptResult{
				Outcome: store.VerificationOutcomeSuccess, Granted: true,
			},
			state: store.VerificationStateCompleted, Outcome: store.VerificationOutcomeSuccess,
		},
		{
			name: "transient",
			result: mdmSchedulerAttemptResult{
				Outcome: store.VerificationOutcomeTransient,
			},
			state: store.VerificationStateBackoff, Outcome: store.VerificationOutcomeTransient,
			stage: 1,
		},
		{
			name: "terminal",
			result: mdmSchedulerAttemptResult{
				Outcome: store.VerificationOutcomeInvalid, Terminal: true,
			},
			state: store.VerificationStateCompleted, Outcome: store.VerificationOutcomeInvalid,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
				Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
			}, mdmSchedulerDeps{
				Jitter: func(minimum, _ time.Duration) time.Duration {
					if minimum >= mdmRetryFirstMin {
						return minimum
					}
					return 0
				},
				ReuseMDA: func(mdmLiveBinding) bool { return true },
				Execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
					return tc.result
				},
			})
			seKey := "se-result-" + tc.name
			provider := schedulerTestProvider(t, srv, "result-"+tc.name, seKey)
			sch.Submit(
				context.Background(), provider.ID, provider,
				store.VerificationPriorityRecovery,
			)
			sch.ChallengeSettled(provider, false)
			waitSchedulerCondition(t, func() bool {
				rec, err := st.GetVerificationJob(
					context.Background(), seKey, store.VerificationTaskSecurityInfo,
				)
				return err == nil && rec != nil &&
					rec.State == tc.state && rec.LastOutcome == tc.Outcome &&
					rec.RetryStage == tc.stage && rec.ClaimOwner == ""
			}, "worker result was released instead of persisted")
		})
	}
}

func TestMDMSchedulerReleaseErrorDropsDisconnectedOrphan(t *testing.T) {
	st := &releaseFailingVerificationStore{MemoryStore: memory.NewMemory(store.Config{})}
	started := make(chan struct{}, 1)
	srv, sch := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			started <- struct{}{}
			<-ctx.Done()
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeCancelled}
		},
	})
	provider := schedulerTestProvider(t, srv, "release-error", "se-release-error")
	generation := sch.Submit(
		context.Background(), provider.ID, provider,
		store.VerificationPriorityRecovery,
	)
	sch.ChallengeSettled(provider, false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("release-error attempt did not start")
	}
	sch.Unbind("se-release-error", generation)
	waitSchedulerCondition(t, func() bool {
		return sch.Candidate(verificationSchedulerKey(
			"se-release-error", store.VerificationTaskSecurityInfo,
		)) == nil
	}, "failed claim release left a disconnected orphan consuming queue memory")
	rec, err := st.GetVerificationJob(
		context.Background(), "se-release-error", store.VerificationTaskSecurityInfo,
	)
	if err != nil || rec == nil || rec.State != store.VerificationStateRunning {
		t.Fatalf("release failure unexpectedly discarded durable recovery state: %+v, err=%v", rec, err)
	}
}

func TestMDMSchedulerFastSkipCancelsBeforeCommand(t *testing.T) {
	var attempts atomic.Int32
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8}, mdmSchedulerDeps{
		Execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			attempts.Add(1)
			return mdmSchedulerAttemptResult{}
		},
	})
	p := schedulerTestProvider(t, srv, "fast", "se-fast")
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

func TestMDMSchedulerCloseReleasesClaimWithLiveCleanupContext(t *testing.T) {
	st := &cancelAwareVerificationStore{MemoryStore: memory.NewMemory(store.Config{})}
	started := make(chan struct{}, 1)
	srv1, sch1 := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, ClaimTTL: 10 * time.Minute,
		InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			started <- struct{}{}
			<-ctx.Done()
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeCancelled}
		},
	})
	first := schedulerTestProvider(t, srv1, "close-first", "se-close-release")
	sch1.Submit(context.Background(), first.ID, first, store.VerificationPriorityRecovery)
	sch1.ChallengeSettled(first, false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first coordinator did not claim work")
	}
	sch1.Close()
	released, err := st.GetVerificationJob(
		context.Background(), "se-close-release",
		store.VerificationTaskSecurityInfo,
	)
	if err != nil || released == nil ||
		released.State != store.VerificationStatePending ||
		released.ClaimOwner != "" {
		t.Fatalf("shutdown claim release = %+v, err=%v", released, err)
	}

	replacementStarted := make(chan struct{}, 1)
	srv2, sch2 := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, ClaimTTL: 10 * time.Minute,
		InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			replacementStarted <- struct{}{}
			return mdmSchedulerAttemptResult{
				Outcome: store.VerificationOutcomeSuccess, Terminal: true,
			}
		},
	})
	replacement := schedulerTestProvider(t, srv2, "close-replacement", "se-close-release")
	sch2.Submit(context.Background(), replacement.ID, replacement, store.VerificationPriorityRecovery)
	sch2.ChallengeSettled(replacement, false)
	select {
	case <-replacementStarted:
	case <-time.After(time.Second):
		t.Fatal("replacement coordinator could not promptly reclaim released work")
	}
}

func TestMDMSchedulerGenerationChurnRetainsNoSEKeys(t *testing.T) {
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 1,
	}, mdmSchedulerDeps{})
	const churn = 2000
	for i := range churn {
		seKey := fmt.Sprintf("se-churn-%d", i)
		provider := schedulerTestProvider(t, srv, fmt.Sprintf("churn-%d", i), seKey)
		generation := sch.Submit(
			context.Background(), provider.ID, provider,
			store.VerificationPriorityRefresh,
		)
		sch.Unbind(seKey, generation)
	}
	status := sch.Status()
	jobs, bindings, udids := status.Jobs, status.Bindings, status.UDIDs
	if jobs != 0 || bindings != 0 || udids != 0 {
		t.Fatalf("scheduler retained per-SE churn state: jobs=%d bindings=%d udids=%d", jobs, bindings, udids)
	}
	if generation := status.Generation; generation != churn {
		t.Fatalf("global generation = %d, want %d", generation, churn)
	}
}
