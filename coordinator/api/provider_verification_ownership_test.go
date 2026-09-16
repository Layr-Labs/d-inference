package api

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/mdmscheduler"
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
	srv.mdmScheduler.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resultCh := make(chan mdmSchedulerAttemptResult, 1)
	deps := srv.mdmSchedulerDependencies()
	executor := mdmscheduler.NewExecutor(deps)
	deps.Jitter = func(time.Duration, time.Duration) time.Duration { return 0 }
	deps.Execute = func(ctx context.Context, target mdmscheduler.Target, kind store.VerificationTaskKind, attemptUDID string) mdmscheduler.AttemptResult {
		result := executor.Execute(ctx, target, kind, attemptUDID)
		resultCh <- result
		// Hold the worker until the test inspects the SecurityInfo result. Fresh
		// MDA can only be scheduled after this attempt returns to the shared pool.
		<-ctx.Done()
		return result
	}
	sch := mdmscheduler.New(MDMSchedulerConfig{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, deps)
	srv.mdmScheduler = sch
	generation := sch.Submit(ctx, provider.ID, provider, store.VerificationPriorityRecovery)
	if generation == 0 {
		t.Fatal("scheduler binding was not created")
	}
	sch.ChallengeSettled(provider, false)
	t.Cleanup(func() { cancel(); sch.Close() })

	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		binding := sch.ApplyLateSecurityInfo(udid, command, true)
		owned := binding != nil && binding.Target().Provider == provider
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
		if ctx.Err() != nil || result.Outcome != store.VerificationOutcomeSuccess ||
			!result.Granted || result.Terminal || result.UDID != udid {
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
