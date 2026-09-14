package mdmscheduler

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerCrossInstanceOldCompletionReopensCurrentBinding(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	st := store.NewMemory(store.Config{})
	oldStarted := make(chan struct{}, 1)
	finishOld := make(chan struct{})
	srvOld, oldScheduler := newSchedulerHarnessWithStore(t, st, Config{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, Dependencies{
		Now: func() time.Time { return now },
		Jitter: func(time.Duration, time.Duration) time.Duration {
			return 0
		},
		ReuseMDA: func(Target) bool { return true },
		Execute: func(ctx context.Context, _ Target, _ store.VerificationTaskKind, _ string) AttemptResult {
			oldStarted <- struct{}{}
			select {
			case <-finishOld:
				return AttemptResult{
					Outcome: store.VerificationOutcomeSuccess,
					Granted: true,
				}
			case <-ctx.Done():
				return AttemptResult{
					Outcome: store.VerificationOutcomeCancelled,
				}
			}
		},
	})
	oldProvider := schedulerProvider(t, srvOld, "cross-old", "se-cross")
	oldScheduler.Submit(context.Background(), oldProvider.ID, oldProvider, store.VerificationPriorityRecovery)
	oldScheduler.ChallengeSettled(oldProvider, false)
	select {
	case <-oldStarted:
	case <-time.After(time.Second):
		t.Fatal("old coordinator did not claim work")
	}

	currentStarted := make(chan struct{}, 1)
	srvCurrent, currentScheduler := newSchedulerHarnessWithStore(t, st, Config{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, Dependencies{
		Now: func() time.Time { return now },
		Jitter: func(time.Duration, time.Duration) time.Duration {
			return 0
		},
		Execute: func(context.Context, Target, store.VerificationTaskKind, string) AttemptResult {
			currentStarted <- struct{}{}
			return AttemptResult{
				Outcome: store.VerificationOutcomeInvalid, Terminal: true,
			}
		},
	})
	currentProvider := schedulerProvider(t, srvCurrent, "cross-current", "se-cross")
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
	st := store.NewMemory(store.Config{})
	oldStarted := make(chan struct{}, 1)
	finishOld := make(chan struct{})
	srvOld, oldScheduler := newSchedulerHarnessWithStore(t, st, Config{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, Dependencies{
		Now:      func() time.Time { return now },
		Jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		ReuseMDA: func(Target) bool { return true },
		Execute: func(ctx context.Context, _ Target, _ store.VerificationTaskKind, _ string) AttemptResult {
			oldStarted <- struct{}{}
			select {
			case <-finishOld:
				return AttemptResult{
					Outcome: store.VerificationOutcomeSuccess,
					Granted: true,
				}
			case <-ctx.Done():
				return AttemptResult{
					Outcome: store.VerificationOutcomeCancelled,
				}
			}
		},
	})
	oldProvider := schedulerProvider(
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
	srvCurrent, currentScheduler := newSchedulerHarnessWithStore(t, st, Config{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, Dependencies{
		Now:    func() time.Time { return now },
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(context.Context, Target, store.VerificationTaskKind, string) AttemptResult {
			currentStarted <- struct{}{}
			return AttemptResult{
				Outcome:  store.VerificationOutcomeInvalid,
				Terminal: true,
			}
		},
	})
	currentProvider := schedulerProvider(
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

func TestMDMSchedulerReconnectDuringInflightRefreshesReleasedClaim(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	started := make(chan struct{}, 1)
	finishOld := make(chan struct{})
	execute := func(ctx context.Context, _ Target, _ store.VerificationTaskKind, _ string) AttemptResult {
		// Only the first start is observed. A rebound attempt must never
		// block on this test notification or prevent Close from cancelling it.
		select {
		case started <- struct{}{}:
		default:
		}
		select {
		case <-finishOld:
			return AttemptResult{
				Outcome: store.VerificationOutcomeTransient,
			}
		case <-ctx.Done():
			return AttemptResult{
				Outcome: store.VerificationOutcomeCancelled,
			}
		}
	}
	srv, st, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, Dependencies{
		Now: func() time.Time { return now },
		Jitter: func(minimum, _ time.Duration) time.Duration {
			if minimum >= retryFirstMin {
				return minimum
			}
			return 0
		},
		Execute: execute,
	})
	old := schedulerProvider(t, srv, "old-generation", "se-inflight")
	sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(old, false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("old attempt did not start")
	}
	newProvider := schedulerProvider(t, srv, "new-generation", "se-inflight")
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
	sch.mu.Lock()
	job := sch.jobs[jobKey("se-inflight", store.VerificationTaskSecurityInfo)]
	inMemoryCurrent := job != nil && job.bindingGen == newGeneration &&
		job.record.State == store.VerificationStateBackoff &&
		job.record.RetryStage == 1 && job.record.ClaimOwner == ""
	sch.mu.Unlock()
	if !inMemoryCurrent {
		t.Fatal("rebound in-memory job did not adopt authoritative backoff state")
	}
	rec, err := st.GetVerificationJob(context.Background(), "se-inflight", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State != store.VerificationStateBackoff ||
		rec.RetryStage != 1 || !rec.NextAttemptAt.Equal(now.Add(retryFirstMin)) {
		t.Fatalf("authoritative rebound state = %+v, err=%v", rec, err)
	}
}

func TestMDMSchedulerWorkerPersistsResultsBeforeCancellingAttempt(t *testing.T) {
	tests := []struct {
		name    string
		result  AttemptResult
		state   store.VerificationTaskState
		outcome store.VerificationOutcome
		stage   int
	}{
		{
			name: "success",
			result: AttemptResult{
				Outcome: store.VerificationOutcomeSuccess, Granted: true,
			},
			state: store.VerificationStateCompleted, outcome: store.VerificationOutcomeSuccess,
		},
		{
			name: "transient",
			result: AttemptResult{
				Outcome: store.VerificationOutcomeTransient,
			},
			state: store.VerificationStateBackoff, outcome: store.VerificationOutcomeTransient,
			stage: 1,
		},
		{
			name: "terminal",
			result: AttemptResult{
				Outcome: store.VerificationOutcomeInvalid, Terminal: true,
			},
			state: store.VerificationStateCompleted, outcome: store.VerificationOutcomeInvalid,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, st, sch := newSchedulerHarness(t, Config{
				Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
			}, Dependencies{
				Jitter: func(minimum, _ time.Duration) time.Duration {
					if minimum >= retryFirstMin {
						return minimum
					}
					return 0
				},
				ReuseMDA: func(Target) bool { return true },
				Execute: func(context.Context, Target, store.VerificationTaskKind, string) AttemptResult {
					return tc.result
				},
			})
			seKey := "se-result-" + tc.name
			provider := schedulerProvider(t, srv, "result-"+tc.name, seKey)
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
					rec.State == tc.state && rec.LastOutcome == tc.outcome &&
					rec.RetryStage == tc.stage && rec.ClaimOwner == ""
			}, "worker result was released instead of persisted")
		})
	}
}

func TestMDMSchedulerReleaseErrorDropsDisconnectedOrphan(t *testing.T) {
	st := &releaseFailingVerificationStore{MemoryStore: store.NewMemory(store.Config{})}
	started := make(chan struct{}, 1)
	srv, sch := newSchedulerHarnessWithStore(t, st, Config{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, Dependencies{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(ctx context.Context, _ Target, _ store.VerificationTaskKind, _ string) AttemptResult {
			started <- struct{}{}
			<-ctx.Done()
			return AttemptResult{Outcome: store.VerificationOutcomeCancelled}
		},
	})
	provider := schedulerProvider(t, srv, "release-error", "se-release-error")
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
		sch.mu.Lock()
		defer sch.mu.Unlock()
		return sch.jobs[jobKey(
			"se-release-error", store.VerificationTaskSecurityInfo,
		)] == nil
	}, "failed claim release left a disconnected orphan consuming queue memory")
	rec, err := st.GetVerificationJob(
		context.Background(), "se-release-error", store.VerificationTaskSecurityInfo,
	)
	if err != nil || rec == nil || rec.State != store.VerificationStateRunning {
		t.Fatalf("release failure unexpectedly discarded durable recovery state: %+v, err=%v", rec, err)
	}
}

func TestMDMSchedulerRetryWindowsPersistAndDoNotSynchronize(t *testing.T) {
	var sequence atomic.Int64
	_, _, sch := newSchedulerHarness(t, Config{}, Dependencies{
		Jitter: func(minimum, maximum time.Duration) time.Duration {
			n := time.Duration(sequence.Add(1))
			return minimum + n%(maximum-minimum)
		},
	})
	seen := map[time.Duration]bool{}
	for stage, bounds := range map[int][2]time.Duration{
		1: {retryFirstMin, retryFirstMax}, 2: {retrySecondMin, retrySecondMax}, 3: {retrySteadyMin, retrySteadyMax},
	} {
		for range 20 {
			delay := sch.retryDelay(stage)
			if delay < bounds[0] || delay > bounds[1] {
				t.Fatalf("stage %d delay %s outside %s..%s", stage, delay, bounds[0], bounds[1])
			}
			seen[delay] = true
		}
	}
	if len(seen) < 10 {
		t.Fatalf("retry jitter synchronized: only %d distinct due offsets", len(seen))
	}
}

func TestMDMSchedulerCloseReleasesClaimWithLiveCleanupContext(t *testing.T) {
	st := &cancelAwareVerificationStore{MemoryStore: store.NewMemory(store.Config{})}
	started := make(chan struct{}, 1)
	srv1, sch1 := newSchedulerHarnessWithStore(t, st, Config{
		Workers: 1, QueueCapacity: 8, ClaimTTL: 10 * time.Minute,
		InitialSpreadMax: time.Nanosecond,
	}, Dependencies{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(ctx context.Context, _ Target, _ store.VerificationTaskKind, _ string) AttemptResult {
			started <- struct{}{}
			<-ctx.Done()
			return AttemptResult{Outcome: store.VerificationOutcomeCancelled}
		},
	})
	first := schedulerProvider(t, srv1, "close-first", "se-close-release")
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
	srv2, sch2 := newSchedulerHarnessWithStore(t, st, Config{
		Workers: 1, QueueCapacity: 8, ClaimTTL: 10 * time.Minute,
		InitialSpreadMax: time.Nanosecond,
	}, Dependencies{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(context.Context, Target, store.VerificationTaskKind, string) AttemptResult {
			replacementStarted <- struct{}{}
			return AttemptResult{
				Outcome: store.VerificationOutcomeSuccess, Terminal: true,
			}
		},
	})
	replacement := schedulerProvider(t, srv2, "close-replacement", "se-close-release")
	sch2.Submit(context.Background(), replacement.ID, replacement, store.VerificationPriorityRecovery)
	sch2.ChallengeSettled(replacement, false)
	select {
	case <-replacementStarted:
	case <-time.After(time.Second):
		t.Fatal("replacement coordinator could not promptly reclaim released work")
	}
}
