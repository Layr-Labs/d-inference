package verification_test

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/store"
	"testing"
	"time"
)

func TestMDMSchedulerObserveAttemptUDIDDoesNotDeadlock(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	started := make(chan struct{})
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, ClaimTTL: time.Minute,
	}, mdmSchedulerDeps{Now: func() time.Time { return now }, Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		close(started)
		<-ctx.Done()
		return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeCancelled}
	}})
	withoutLiveDispatcher(sch)
	provider := schedulerTestProvider(t, srv, "observe", "se-observe")
	_, err := st.UpsertVerificationJob(context.Background(), store.VerificationJob{
		SEPubKey: "se-observe", Serial: "serial-observe",
		Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending,
		Priority: store.VerificationPriorityRecovery, NextAttemptAt: now, UpdatedAt: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	generation := sch.Submit(context.Background(), provider.ID, provider, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(provider, false)
	sch.StartWorkers()
	sch.DispatchDueRows()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("observer attempt did not start")
	}
	claimed, err := st.GetVerificationJob(context.Background(), "se-observe", store.VerificationTaskSecurityInfo)
	claimView := sch.Candidate(verificationSchedulerKey("se-observe", store.VerificationTaskSecurityInfo))
	ok := claimed != nil && claimView != nil && claimView.Running &&
		claimed.State == store.VerificationStateRunning && claimed.ClaimOwner != "" &&
		claimed.ClaimOwner == claimView.Record.ClaimOwner && claimed.ClaimExpiresAt != nil &&
		claimed.ClaimExpiresAt.Equal(now.Add(time.Minute))
	if err != nil || !ok {
		t.Fatalf("claim observe job: ok=%v err=%v", ok, err)
	}

	done := make(chan struct{})
	go func() {
		sch.ObserveAttemptUDID(provider, "udid-observe")
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("ObserveAttemptUDID deadlocked while persisting the observed UDID")
	}
	job := sch.Candidate(verificationSchedulerKey("se-observe", store.VerificationTaskSecurityInfo))
	udidOnly := job != nil && job.Record.UDID == "udid-observe" &&
		sch.ApplyLateSecurityInfo("udid-observe", "command-observe", true) == nil &&
		sch.ApplyLateSecurityInfo("udid-observe", "", true) == nil && sch.Status().UDIDs == 0
	if !udidOnly {
		t.Fatal("UDID observation created callback authority before command binding")
	}
	sch.ObserveAttemptCommand(
		provider, store.VerificationTaskSecurityInfo,
		"udid-observe", "command-observe",
	)
	bound := sch.ApplyLateSecurityInfo("udid-observe", "command-observe", true)
	exact := bound != nil && bound.Generation == generation && sch.Status().UDIDs == 1 &&
		sch.ApplyLateSecurityInfo("udid-observe", "different-command", true) == nil
	if !exact {
		t.Fatal("command observation did not bind exact late-callback ownership")
	}
}

func TestMDMSchedulerHardUntrustAndLateSecurityInfoUseCurrentExactBinding(t *testing.T) {
	started := make(chan struct{}, 2)
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8}, mdmSchedulerDeps{Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		started <- struct{}{}
		<-ctx.Done()
		return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeCancelled}
	}})
	withoutLiveDispatcher(sch)
	sch.StartWorkers()
	old := schedulerTestProvider(t, srv, "late-old", "se-late")
	g1 := sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(old, false)
	sch.DispatchDueRows()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("old callback attempt did not start")
	}
	sch.ObserveAttemptUDID(old, "udid-exact")
	sch.ObserveAttemptCommand(old, store.VerificationTaskSecurityInfo, "udid-exact", "old-command")

	newProvider := schedulerTestProvider(t, srv, "late-new", "se-late")
	g2 := sch.Submit(context.Background(), newProvider.ID, newProvider, store.VerificationPriorityRecovery)
	if g2 <= g1 {
		t.Fatal("generation did not advance")
	}
	if sch.ApplyLateSecurityInfo(
		"udid-exact", "old-command", true,
	) != nil {
		t.Fatal("old-connection SecurityInfo bound before the new challenge settled")
	}
	sch.ChallengeSettled(newProvider, false)
	if sch.ApplyLateSecurityInfo(
		"udid-exact", "old-command", true,
	) != nil {
		t.Fatal("old-connection SecurityInfo survived the reconnect generation")
	}
	waitSchedulerCondition(t, func() bool {
		c := sch.Candidate(verificationSchedulerKey("se-late", store.VerificationTaskSecurityInfo))
		return c != nil && !c.Running && c.Record.ClaimOwner == ""
	}, "old attempt did not release its claim")
	sch.DispatchDueRows()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("replacement callback attempt did not start")
	}
	sch.ObserveAttemptUDID(newProvider, "udid-exact")
	sch.ObserveAttemptCommand(
		newProvider, store.VerificationTaskSecurityInfo,
		"udid-exact", "new-command",
	)
	if sch.ApplyLateSecurityInfo(
		"udid-exact", "old-command", true,
	) != nil {
		t.Fatal("old command UUID bound to the current scheduler generation")
	}
	binding := sch.ApplyLateSecurityInfo(
		"udid-exact", "new-command", true,
	)
	if binding == nil || binding.Provider != newProvider {
		t.Fatal("late SecurityInfo did not resolve the new generation's exact command")
	}
	if sch.ApplyLateSecurityInfo(
		"udid-other", "new-command", true,
	) != nil {
		t.Fatal("late SecurityInfo attached to a different UDID/provider")
	}
	srv.registry.MarkUntrusted(newProvider.ID)
	if newProvider.GrantHardwareIfNotUntrusted() {
		t.Fatal("late grant resurrected hard-untrusted provider")
	}
}
