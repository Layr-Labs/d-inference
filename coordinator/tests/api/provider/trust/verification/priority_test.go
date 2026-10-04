package verification_test

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/store"
	"testing"
	"time"
)

// TestMDMSchedulerFirstOrExpiredDueImmediatelyDespiteSpread pins the P1 fix:
// the configured 5s–5m initial spread must never delay first/expired work,
// whose provider has no usable trust grant while a client request burns the
// 120s dispatch-queue deadline. Even with worst-case jitter, a first/expired
// settle becomes due within mdmFirstVerifySpreadMax, while a refresh settle
// keeps the full configured spread.
func TestMDMSchedulerFirstOrExpiredDueImmediatelyDespiteSpread(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, mdmSchedulerDeps{
		Now: func() time.Time { return now },
		// Worst-case draw: whatever range the scheduler requests, take its top.
		Jitter: func(_, maximum time.Duration) time.Duration { return maximum },
	})

	first := schedulerTestProvider(t, srv, "urgent", "se-urgent")
	sch.Submit(context.Background(), first.ID, first, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(first, false)
	rec, err := st.GetVerificationJob(context.Background(), "se-urgent", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil {
		t.Fatalf("first/expired job not persisted: %+v, %v", rec, err)
	}
	if due := rec.NextAttemptAt.Sub(now); due > mdmFirstVerifySpreadMax {
		t.Fatalf("first/expired due %s after settle, must be within %s", due, mdmFirstVerifySpreadMax)
	}

	refresh := schedulerTestProvider(t, srv, "routine", "se-routine")
	sch.Submit(context.Background(), refresh.ID, refresh, store.VerificationPriorityRefresh)
	sch.ChallengeSettled(refresh, false)
	rec, err = st.GetVerificationJob(context.Background(), "se-routine", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil {
		t.Fatalf("refresh job not persisted: %+v, %v", rec, err)
	}
	if due := rec.NextAttemptAt.Sub(now); due != 20*time.Minute {
		t.Fatalf("refresh due %s after settle, want the full 20m spread", due)
	}
}

// TestMDMSchedulerFirstOrExpiredDispatchesBeforeRefreshSpread proves the fix
// end-to-end on the real dispatch loop: with the production floor of each
// jitter range, a first/expired settle executes immediately while a refresh
// settle stays parked behind its spread floor.
func TestMDMSchedulerFirstOrExpiredDispatchesBeforeRefreshSpread(t *testing.T) {
	executed := make(chan string, 4)
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 2, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, mdmSchedulerDeps{
		Jitter: func(minimum, _ time.Duration) time.Duration { return minimum },
		Execute: func(_ context.Context, binding mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			executed <- binding.Attestation.PublicKey
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeSuccess, Terminal: true}
		},
	})

	refresh := schedulerTestProvider(t, srv, "routine", "se-routine")
	sch.Submit(context.Background(), refresh.ID, refresh, store.VerificationPriorityRefresh)
	sch.ChallengeSettled(refresh, false)
	urgent := schedulerTestProvider(t, srv, "urgent", "se-urgent")
	sch.Submit(context.Background(), urgent.ID, urgent, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(urgent, false)

	select {
	case seKey := <-executed:
		if seKey != "se-urgent" {
			t.Fatalf("dispatched %q first, want the first/expired provider", seKey)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("first/expired verification never dispatched; initial spread deferred it")
	}
	select {
	case seKey := <-executed:
		t.Fatalf("refresh %q dispatched inside its spread floor", seKey)
	case <-time.After(100 * time.Millisecond):
	}
}

// TestFailedFastSkipPromotesRefreshToImmediateDue (Codex P1): a job classified
// refresh at submit (hasFreshRecord looked good) whose fast-skip then DECLINES
// must not settle onto the refresh spread — the provider holds no usable trust
// grant while a routed client request burns the 120s dispatch-queue deadline.
// The production read path calls PromoteFailedFastSkip before the settle, and
// the durable row must come out first/expired and due within
// mdmFirstVerifySpreadMax even under worst-case jitter.
func TestFailedFastSkipPromotesRefreshToImmediateDue(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, mdmSchedulerDeps{
		Now: func() time.Time { return now },
		// Worst-case draw: whatever range the scheduler requests, take its top.
		Jitter: func(_, maximum time.Duration) time.Duration { return maximum },
	})

	p := schedulerTestProvider(t, srv, "miss", "se-miss")
	sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	sch.PromoteFailedFastSkip(p)
	sch.ChallengeSettled(p, false)

	rec, err := st.GetVerificationJob(context.Background(), "se-miss", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil {
		t.Fatalf("promoted job not persisted: %+v, %v", rec, err)
	}
	if rec.Priority != store.VerificationPriorityFirstOrExpired {
		t.Fatalf("priority = %q after failed fast-skip, want promoted first/expired", rec.Priority)
	}
	if due := rec.NextAttemptAt.Sub(now); due > mdmFirstVerifySpreadMax {
		t.Fatalf("failed fast-skip settle due %s out, must be within %s", due, mdmFirstVerifySpreadMax)
	}
}
