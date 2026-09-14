package api

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The real transport publishes UDID and command ownership before the webhook.
// The scheduler must receive that same attempt's observed UDID on completion,
// while scheduled SecurityInfo leaves fresh MDA work to the shared worker budget.
func TestScheduledSecurityInfoKeepsItsAttemptObservations(t *testing.T) {
	const udid, command = "UDID-1", "owned-security-info"
	fake := &fakeMDMServer{
		device: &mdm.DeviceInfo{
			SerialNumber: "SERIAL-1", UDID: udid, EnrollmentStatus: true,
		},
		commandUUID: command,
	}
	srv, provider := mdmReliabilityServer(t, fake)
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatal(err)
	}
	sch := srv.mdmScheduler
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ar := attestResultOf(provider)
	now := time.Now()
	pending, err := srv.store.UpsertVerificationJob(ctx, store.VerificationJob{
		SEPubKey: ar.PublicKey, Serial: ar.SerialNumber,
		Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending,
		Priority: store.VerificationPriorityRecovery, NextAttemptAt: now, UpdatedAt: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	claimed, ok, err := srv.store.ClaimVerificationJob(
		ctx, pending.SEPubKey, pending.Kind, sch.owner, now, now.Add(time.Minute),
	)
	if err != nil || !ok {
		t.Fatalf("claim attempt: ok=%v err=%v", ok, err)
	}
	generation := sch.generation.Add(1)
	binding := mdmLiveBinding{
		providerID: provider.ID, provider: provider, attestation: ar,
		generation: generation, ctx: ctx, challengeSettled: true,
	}
	key := verificationSchedulerKey(claimed.SEPubKey, claimed.Kind)
	sch.mu.Lock()
	sch.bindings[ar.PublicKey] = &binding
	sch.jobs[key] = &mdmScheduledJob{record: claimed, bindingGen: generation, running: true}
	sch.mu.Unlock()

	resultCh := make(chan mdmSchedulerAttemptResult, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		resultCh <- srv.executeScheduledVerification(ctx, binding, store.VerificationTaskSecurityInfo, "")
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Error("scheduled verification did not stop after cancellation")
		}
	})

	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		sch.mu.Lock()
		job := sch.jobs[key]
		owned := job != nil && job.record.UDID == udid &&
			job.callbackGen == generation && job.callbackUUID == command &&
			sch.byUDID[udid] == key
		sch.mu.Unlock()
		if owned {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("transport did not publish this attempt's UDID and command ownership")
		case <-ticker.C:
		}
	}
	srv.mdmClient.HandleWebhook(securityInfoWebhook(udid, command, true, true))
	select {
	case result := <-resultCh:
		if ctx.Err() != nil || result.outcome != store.VerificationOutcomeSuccess ||
			!result.granted || result.terminal || result.udid != udid {
			t.Fatalf("scheduled attempt lost its observation or result: %+v ctx=%v", result, ctx.Err())
		}
	case <-ctx.Done():
		t.Fatal("scheduled SecurityInfo did not finish after its matching webhook")
	}
	if provider.GetTrustLevel() != registry.TrustHardware || provider.GetMDMFailureReason() != "" {
		t.Fatal("matching SecurityInfo did not grant hardware and clear the failure reason")
	}
	if command := fake.lastMDACommandUUID(); command != "" {
		t.Fatalf("scheduled SecurityInfo issued fresh MDA outside its worker budget: %s", command)
	}
}
