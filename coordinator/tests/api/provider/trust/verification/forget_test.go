package verification_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// After a scrub the in-memory MDM scheduler must not keep the erased
// account's jobs, bindings or UDID routes, and cancels its running attempt;
// other keys stay.
func TestMDMSchedulerForgetDropsErasedKeys(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	started, canceled := make(chan struct{}), make(chan struct{})
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, ClaimTTL: time.Minute,
	}, mdmSchedulerDeps{Now: func() time.Time { return now }, Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		close(started)
		<-ctx.Done()
		close(canceled)
		return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeCancelled}
	}})
	withoutLiveDispatcher(sch)
	erased := schedulerTestProvider(t, srv, "erased", "se-erased")
	if _, err := st.UpsertVerificationJob(ctx, store.VerificationJob{
		SEPubKey: "se-erased", Serial: "serial-erased",
		Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending,
		Priority: store.VerificationPriorityRecovery, NextAttemptAt: now, UpdatedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	sch.Submit(ctx, erased.ID, erased, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(erased, false)
	sch.StartWorkers()
	sch.DispatchDueRows()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("attempt did not start")
	}
	sch.ObserveAttemptUDID(erased, "udid-erased")
	sch.ObserveAttemptCommand(erased, store.VerificationTaskSecurityInfo, "udid-erased", "command-erased")
	kept := schedulerTestProvider(t, srv, "kept", "se-kept")
	sch.Submit(ctx, kept.ID, kept, store.VerificationPriorityRefresh)
	if before := sch.Status(); before.Jobs != 2 || before.Bindings != 2 || before.UDIDs != 1 {
		t.Fatalf("status before Forget = %+v", before)
	}

	sch.Forget([]string{"se-erased"})

	select {
	case <-canceled:
	case <-time.After(time.Second):
		t.Fatal("Forget did not cancel the running attempt")
	}
	if after := sch.Status(); after.Bindings != 1 || after.UDIDs != 0 {
		t.Fatalf("status after Forget = %+v", after)
	}
	if sch.ApplyLateSecurityInfo("udid-erased", "command-erased", true) != nil {
		t.Fatal("a late callback still reaches the erased key")
	}
	if c := sch.Candidate(verificationSchedulerKey("se-kept", store.VerificationTaskSecurityInfo)); c == nil || c.Binding.Provider != kept {
		t.Fatalf("Forget removed another key: %+v", c)
	}
	var nilScheduler *verification.Scheduler
	nilScheduler.Forget([]string{"se-erased"})
}
