package api

import (
	"context"
	"crypto/sha256"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Durable claims stay on the startup store while a late, exactly owned proof
// uses the current registry's persistence store and current metrics. The real
// worker is held at its observed MDA command after the bindings are replaced.
func TestMDMSchedulerKeepsClaimsAndCurrentLateBindings(t *testing.T) {
	const udid, command = "late-owner-udid", "late-owner-command"
	observed := make(chan struct{})
	var srv *Server
	var startup *store.MemoryStore
	var sch *mdmVerificationScheduler
	srv, startup, sch = newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute: func(ctx context.Context, target mdmLiveBinding, kind store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			if kind == store.VerificationTaskSecurityInfo {
				return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true, UDID: udid}
			}
			srv.mdmScheduler.ObserveAttemptCommand(target.Provider, kind, udid, command)
			close(observed)
			<-ctx.Done()
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeCancelled}
		},
	})
	provider := schedulerTestProvider(t, srv, "late-owner-provider", "late-owner-se")
	provider.Mu().Lock()
	provider.TrustLevel = registry.TrustHardware
	provider.Mu().Unlock()
	// Replace bindings before Submit starts the dispatcher; no field write
	// races a background telemetry observation. The owner was built above.
	oldMetrics := srv.metrics
	current := store.NewMemory(store.Config{})
	currentRegistry := registry.New(srv.logger)
	currentRegistry.SetStore(current)
	srv.store = current
	srv.registry = currentRegistry
	srv.metrics = NewMetrics()

	sch.Submit(context.Background(), provider.ID, provider, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(provider, false)
	select {
	case <-observed:
	case <-time.After(3 * time.Second):
		t.Fatal("MDA worker did not publish its exact command")
	}
	running, err := startup.GetVerificationJob(context.Background(), "late-owner-se", store.VerificationTaskMDA)
	if err != nil || running == nil || running.State != store.VerificationStateRunning || running.ClaimOwner == "" {
		t.Fatalf("startup claim = %+v, %v", running, err)
	}

	freshness := sha256.Sum256([]byte("late-owner-se"))
	chain, root := mintMDALeafChain(t, "serial-late-owner-provider", freshness[:])
	restore := attestation.OverrideRootCAForTest(root)
	defer restore()
	srv.ApplyLateMDA(udid, command, chain)

	waitSchedulerCondition(t, func() bool {
		rec, err := current.GetProviderRecord(context.Background(), provider.ID)
		return err == nil && rec != nil && rec.MDAVerified && len(rec.MDACertChain) > 0
	}, "late MDA proof did not persist through the current registry")
	completed, err := startup.GetVerificationJob(context.Background(), "late-owner-se", store.VerificationTaskMDA)
	if err != nil || completed == nil || completed.State != store.VerificationStateCompleted || completed.LastOutcome != store.VerificationOutcomeSuccess {
		t.Fatalf("startup completion = %+v, %v", completed, err)
	}
	if rec, err := current.GetVerificationJob(context.Background(), "late-owner-se", store.VerificationTaskMDA); err != nil || rec != nil {
		t.Fatalf("scheduler claim leaked to current provider store: %+v, %v", rec, err)
	}
	if rec, err := startup.GetProviderRecord(context.Background(), provider.ID); err == nil && rec != nil && rec.MDAVerified {
		t.Fatal("late proof persisted through the captured registry")
	}
	const lateMetric = "mda_verification_total{outcome=\"late\"} 1"
	if !strings.Contains(srv.metrics.Snapshot().RenderProm(), lateMetric) {
		t.Fatal("late MDA did not update current metrics")
	}
	if strings.Contains(oldMetrics.Snapshot().RenderProm(), lateMetric) {
		t.Fatal("late MDA updated captured metrics")
	}
}
