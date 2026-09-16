package mdmscheduler

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerQueueFullRemainsDurableAndRestartReseeds(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 1}, Dependencies{Now: func() time.Time { return now }})
	first := schedulerProvider(t, srv, "queue-one", "se-queue-one")
	second := schedulerProvider(t, srv, "queue-two", "se-queue-two")
	sch.Submit(context.Background(), first.ID, first, store.VerificationPriorityRefresh)
	sch.Submit(context.Background(), second.ID, second, store.VerificationPriorityRefresh)
	sch.mu.Lock()
	inMemory := len(sch.jobs)
	sch.mu.Unlock()
	if inMemory != 1 {
		t.Fatalf("bounded queue contains %d jobs", inMemory)
	}
	persisted, err := st.GetVerificationJob(context.Background(), "se-queue-two", store.VerificationTaskSecurityInfo)
	if err != nil || persisted == nil {
		t.Fatalf("queue-full job not durable: %+v, %v", persisted, err)
	}

	due := now.Add(11 * time.Minute)
	_, err = st.UpsertVerificationJob(context.Background(), store.VerificationJob{SEPubKey: "se-reseed", Serial: "serial", Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStateBackoff, Priority: store.VerificationPriorityRecovery, RetryStage: 2, PreviousDelay: 11 * time.Minute, NextAttemptAt: due, LastOutcome: store.VerificationOutcomeTimeout, UpdatedAt: now})
	if err != nil {
		t.Fatal(err)
	}
	reseed := schedulerProvider(t, srv, "reseed", "se-reseed")
	sch.Submit(context.Background(), reseed.ID, reseed, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(reseed, false)
	rec, _ := st.GetVerificationJob(context.Background(), "se-reseed", store.VerificationTaskSecurityInfo)
	if rec.RetryStage != 2 || !rec.NextAttemptAt.Equal(due) {
		t.Fatalf("restart/reconnect reset backoff: %+v", rec)
	}
}

func TestMDMSchedulerQueueRejectedChallengeSettlesDurablyAndReseeds(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var clock atomic.Int64
	clock.Store(now.UnixNano())
	nowFn := func() time.Time { return time.Unix(0, clock.Load()).UTC() }
	srv, st, sch := newSchedulerHarness(t, Config{
		Workers: 1, QueueCapacity: 1,
		InitialSpreadMin: 3 * time.Minute, InitialSpreadMax: 3 * time.Minute,
	}, Dependencies{Now: nowFn, Jitter: func(time.Duration, time.Duration) time.Duration {
		return 3 * time.Minute
	}})
	withoutLiveDispatcher(sch)
	evicted := schedulerProvider(t, srv, "evicted-refresh", "se-evicted-refresh")
	sch.Submit(context.Background(), evicted.ID, evicted, store.VerificationPriorityRefresh)
	urgent := schedulerProvider(t, srv, "urgent-first", "se-urgent-first")
	urgentGeneration := sch.Submit(
		context.Background(), urgent.ID, urgent,
		store.VerificationPriorityFirstOrExpired,
	)

	sch.ChallengeSettled(evicted, false)
	durable, err := st.GetVerificationJob(
		context.Background(), "se-evicted-refresh",
		store.VerificationTaskSecurityInfo,
	)
	wantDue := now.Add(3 * time.Minute)
	if err != nil || durable == nil ||
		durable.State != store.VerificationStatePending ||
		!durable.NextAttemptAt.Equal(wantDue) {
		t.Fatalf("evicted challenge settlement = %+v, err=%v", durable, err)
	}
	sch.Unbind("se-urgent-first", urgentGeneration)
	clock.Store(wantDue.UnixNano())
	sch.loadDueRows()
	found, reseededDue := schedulerJobDue(sch, "se-evicted-refresh", store.VerificationTaskSecurityInfo)
	if !found || !reseededDue.Equal(wantDue) {
		t.Fatalf("durable queue-pressure job was not reseeded at preserved due time: found=%v due=%s", found, reseededDue)
	}
}

func TestMDMSchedulerDuePagingCannotStarveLiveRowBehindDisconnectedPrefix(t *testing.T) {
	base := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	due := base.Add(time.Hour)
	var clock atomic.Int64
	clock.Store(base.UnixNano())
	nowFn := func() time.Time { return time.Unix(0, clock.Load()).UTC() }
	srv, st, sch := newSchedulerHarness(t, Config{
		Workers: 1, QueueCapacity: 2,
		InitialSpreadMin: time.Hour, InitialSpreadMax: time.Hour,
	}, Dependencies{
		Now: nowFn,
		Jitter: func(time.Duration, time.Duration) time.Duration {
			return time.Hour
		},
	})
	withoutLiveDispatcher(sch)
	for i := range 5 {
		_, err := st.UpsertVerificationJob(context.Background(), store.VerificationJob{
			SEPubKey:      fmt.Sprintf("a-disconnected-%02d", i),
			Serial:        fmt.Sprintf("serial-disconnected-%02d", i),
			Kind:          store.VerificationTaskSecurityInfo,
			State:         store.VerificationStatePending,
			Priority:      store.VerificationPriorityFirstOrExpired,
			NextAttemptAt: due,
			UpdatedAt:     base,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	first := schedulerProvider(t, srv, "paging-filler-1", "se-paging-filler-1")
	second := schedulerProvider(t, srv, "paging-filler-2", "se-paging-filler-2")
	firstGeneration := sch.Submit(
		context.Background(), first.ID, first, store.VerificationPriorityRefresh,
	)
	secondGeneration := sch.Submit(
		context.Background(), second.ID, second, store.VerificationPriorityRefresh,
	)
	live := schedulerProvider(t, srv, "paging-live", "z-se-paging-live")
	sch.Submit(
		context.Background(), live.ID, live, store.VerificationPriorityRefresh,
	)
	sch.ChallengeSettled(live, false)
	sch.Unbind("se-paging-filler-1", firstGeneration)
	sch.Unbind("se-paging-filler-2", secondGeneration)

	clock.Store(due.UnixNano())
	for range 4 {
		sch.loadDueRows()
	}
	found, reseededDue := schedulerJobDue(sch, "z-se-paging-live", store.VerificationTaskSecurityInfo)
	if !found {
		t.Fatal("live queue-rejected row remained hidden behind disconnected due-row prefix")
	}
	if !reseededDue.Equal(due) {
		t.Fatalf("paged reseed due = %s, want %s", reseededDue, due)
	}
}

func TestMDMSchedulerRestartBeforeClaimExpiryReclaimsAfterExpiry(t *testing.T) {
	base := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var clock atomic.Int64
	clock.Store(base.UnixNano())
	nowFn := func() time.Time { return time.Unix(0, clock.Load()).UTC() }
	st := store.NewMemory(store.Config{})
	_, err := st.UpsertVerificationJob(context.Background(), store.VerificationJob{
		SEPubKey: "se-expired-claim", Serial: "serial-expired-claim",
		Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending,
		Priority: store.VerificationPriorityRecovery, NextAttemptAt: base, UpdatedAt: base,
	})
	if err != nil {
		t.Fatal(err)
	}
	expiry := base.Add(time.Minute)
	if _, ok, claimErr := st.ClaimVerificationJob(
		context.Background(), "se-expired-claim",
		store.VerificationTaskSecurityInfo, "dead-coordinator", base, expiry,
	); claimErr != nil || !ok {
		t.Fatalf("seed expired claim: ok=%v err=%v", ok, claimErr)
	}
	attempted := make(chan struct{}, 1)
	srv, sch := newSchedulerHarnessWithStore(t, st, Config{
		Workers: 1, QueueCapacity: 8, ClaimTTL: 5 * time.Minute,
		InitialSpreadMax: time.Nanosecond,
	}, Dependencies{
		Now:    nowFn,
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(context.Context, Target, store.VerificationTaskKind, string) AttemptResult {
			attempted <- struct{}{}
			return AttemptResult{
				Outcome: store.VerificationOutcomeSuccess, Terminal: true,
			}
		},
	})
	provider := schedulerProvider(t, srv, "expired-claim", "se-expired-claim")
	sch.Submit(context.Background(), provider.ID, provider, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(provider, false)
	select {
	case <-attempted:
		t.Fatal("replacement coordinator stole a live claim")
	case <-time.After(20 * time.Millisecond):
	}
	clock.Store(expiry.Add(time.Nanosecond).UnixNano())
	sch.signal()
	select {
	case <-attempted:
	case <-time.After(time.Second):
		t.Fatal("expired running placeholder was not reloaded and reclaimed")
	}
}
