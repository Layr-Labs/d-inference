package verification_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerOperationalViewsAreDetached(t *testing.T) {
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8}, mdmSchedulerDeps{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			<-ctx.Done()
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeCancelled}
		},
	})
	withoutLiveDispatcher(sch)
	p := schedulerTestProvider(t, srv, "detached", "se-detached")
	p.Mu().Lock()
	p.AttestationResult.RuntimeCapabilities = []string{"tools"}
	p.Mu().Unlock()
	generation := sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(p, false)
	status := sch.Status()
	status.Depth[store.VerificationTaskSecurityInfo][store.VerificationPriorityRecovery] = 99
	if got := sch.Status().Depth[store.VerificationTaskSecurityInfo][store.VerificationPriorityRecovery]; got != 1 {
		t.Fatalf("detached queue depth mutation changed live depth: %d", got)
	}
	sch.StartWorkers()
	sch.DispatchDueRows()
	key := verificationSchedulerKey("se-detached", store.VerificationTaskSecurityInfo)
	candidate := sch.Candidate(key)
	if candidate == nil || !candidate.Running || candidate.Record.ClaimExpiresAt == nil {
		t.Fatalf("dispatch did not retain a claimed candidate: %+v", candidate)
	}
	expiry := *candidate.Record.ClaimExpiresAt
	*candidate.Record.ClaimExpiresAt = time.Time{}
	candidate.Record.State = store.VerificationStateCompleted
	candidate.Binding.ProviderID = "unrelated"
	candidate.Binding.Attestation.RuntimeCapabilities[0] = "unrelated"
	fresh := sch.Candidate(key)
	if fresh.BindingGen != generation || fresh.Record.State != store.VerificationStateRunning || !fresh.Record.ClaimExpiresAt.Equal(expiry) || fresh.Binding.ProviderID != p.ID || fresh.Binding.Attestation.RuntimeCapabilities[0] != "tools" {
		t.Fatalf("detached candidate mutation changed live ownership: %+v", fresh)
	}
	status = sch.Status()
	status.Active[store.VerificationTaskSecurityInfo] = 99
	if got := sch.Status().Active[store.VerificationTaskSecurityInfo]; got != 1 {
		t.Fatalf("detached active mutation changed live count: %d", got)
	}
}
