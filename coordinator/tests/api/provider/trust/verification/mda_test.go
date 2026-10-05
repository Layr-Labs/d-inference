package verification_test

import (
	"context"
	"crypto/sha256"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"testing"
	"time"
)

func TestMDMSchedulerMDAUsesSharedCapAndLowerPriority(t *testing.T) {
	kindStarted := make(chan store.VerificationTaskKind, 2)
	release := make(chan struct{}, 2)
	execute := func(ctx context.Context, binding mdmLiveBinding, kind store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		if kind == store.VerificationTaskSecurityInfo && binding.ProviderID == "mda" {
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true, UDID: "udid-mda"}
		}
		kindStarted <- kind
		select {
		case <-release:
		case <-ctx.Done():
		}
		return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeInvalid, Terminal: true}
	}
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, mdmSchedulerDeps{Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: execute})
	withoutLiveDispatcher(sch)
	mdaProvider := schedulerTestProvider(t, srv, "mda", "se-mda")
	mdaProvider.Mu().Lock()
	mdaProvider.TrustLevel = registry.TrustHardware
	mdaProvider.Mu().Unlock()
	mdaGeneration := sch.Submit(context.Background(), mdaProvider.ID, mdaProvider, store.VerificationPriorityRefresh)
	sch.ChallengeSettled(mdaProvider, false)
	sch.StartWorkers()
	sch.DispatchDueRows()
	waitSchedulerCondition(t, func() bool {
		return sch.Candidate(verificationSchedulerKey("se-mda", store.VerificationTaskMDA)) != nil && sch.Status().Active[store.VerificationTaskSecurityInfo] == 0
	}, "MDA follow-on was not enqueued")
	security := schedulerTestProvider(t, srv, "security", "se-security")
	now := sch.deps.Now().UTC()
	_, err := st.UpsertVerificationJob(context.Background(), store.VerificationJob{
		SEPubKey: "se-security", Serial: "serial-security",
		Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending,
		Priority: store.VerificationPriorityFirstOrExpired, NextAttemptAt: now, UpdatedAt: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	securityGeneration := sch.Submit(context.Background(), security.ID, security, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(security, false)
	if mdaGeneration != 1 || securityGeneration != mdaGeneration+1 {
		t.Fatalf("successive registration generations = %d/%d", mdaGeneration, securityGeneration)
	}
	securityCandidate := sch.Candidate(verificationSchedulerKey("se-security", store.VerificationTaskSecurityInfo))
	if securityCandidate == nil || securityCandidate.Binding.Attestation.PublicKey != "se-security" || securityCandidate.BindingGen != securityGeneration {
		t.Fatal("SecurityInfo candidate lost exact registration ownership")
	}
	sch.Start()
	sch.Wake()
	select {
	case kind := <-kindStarted:
		if kind != store.VerificationTaskSecurityInfo {
			t.Fatalf("lower-priority MDA started before SecurityInfo: %s", kind)
		}
	case <-time.After(time.Second):
		t.Fatal("no shared-budget attempt started")
	}
	totalActive := 0
	for _, n := range sch.Status().Active {
		totalActive += n
	}
	if totalActive != 1 {
		t.Fatalf("shared active budget = %d, want 1", totalActive)
	}
	release <- struct{}{}
	select {
	case kind := <-kindStarted:
		if kind != store.VerificationTaskMDA {
			t.Fatalf("second kind = %s", kind)
		}
	case <-time.After(time.Second):
		t.Fatal("MDA follow-on did not run")
	}
	release <- struct{}{}
}

func TestMDMSchedulerLateMDACompletesExactUDIDAndSEJob(t *testing.T) {
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8}, mdaCommandDependencies("udid-late-mda"))
	withoutLiveDispatcher(sch)
	exact := schedulerTestProvider(t, srv, "late-mda-exact", "se-late-mda")
	other := schedulerTestProvider(t, srv, "late-mda-other", "se-other-mda")
	exact.Mu().Lock()
	exact.TrustLevel = registry.TrustHardware
	exact.Mu().Unlock()
	other.Mu().Lock()
	other.TrustLevel = registry.TrustHardware
	other.Mu().Unlock()
	mdaGeneration := sch.Submit(context.Background(), exact.ID, exact, store.VerificationPriorityRefresh)
	if mdaGeneration != 1 {
		t.Fatalf("initial MDA registration generation = %d", mdaGeneration)
	}
	binding := mdmLiveBinding{
		ProviderID: exact.ID, Provider: exact,
		Attestation: *exact.GetAttestationResult(),
		Generation:  mdaGeneration, Context: context.Background(),
		ChallengeSettled: false, AllowMDA: true,
	}
	record := store.VerificationJob{SEPubKey: "se-late-mda", UDID: "udid-late-mda", Kind: store.VerificationTaskMDA}
	freshness := sha256.Sum256([]byte("se-late-mda"))
	chain, root := mintMDALeafChain(t, "serial-late-mda-exact", freshness[:])
	restore := attestation.OverrideRootCAForTest(root)
	defer restore()
	if _, consumed := verification.ResolveMDACallback(record, binding, mdaGeneration, mdaGeneration, "mda-command", "different-udid", "mda-command"); consumed {
		t.Fatal("late MDA attached without exact scheduler UDID ownership")
	}
	resolved, consumed := verification.ResolveMDACallback(record, binding, mdaGeneration, mdaGeneration, "mda-command", "udid-late-mda", "mda-command")
	if !consumed || resolved != nil {
		t.Fatal("exact but unchallenged late MDA callback was not consumed and dropped")
	}
	exact.Mu().Lock()
	verifiedBeforeChallenge := exact.MDAVerified
	exact.Mu().Unlock()
	if verifiedBeforeChallenge {
		t.Fatal("late MDA granted before the current challenge settled")
	}
	sch.ChallengeSettled(exact, false)
	startMDACommand(t, sch, "se-late-mda", exact, "udid-late-mda", "mda-command")
	challenged := sch.Candidate(verificationSchedulerKey("se-late-mda", store.VerificationTaskMDA))
	if challenged == nil || challenged.BindingGen != mdaGeneration || !challenged.Binding.ChallengeSettled {
		t.Fatal("late MDA command lost the exact challenged registration")
	}
	if !sch.ApplyLateMDA("udid-late-mda", "mda-command", chain) {
		t.Fatal("exact challenged scheduled late MDA was not consumed")
	}
	exact.Mu().Lock()
	exactVerified := exact.MDAVerified
	exact.Mu().Unlock()
	other.Mu().Lock()
	otherVerified := other.MDAVerified
	other.Mu().Unlock()
	if !exactVerified || otherVerified {
		t.Fatalf("late MDA attachment exact=%v other=%v", exactVerified, otherVerified)
	}
	rec, err := st.GetVerificationJob(context.Background(), "se-late-mda", store.VerificationTaskMDA)
	if err != nil || rec == nil || rec.State != store.VerificationStateCompleted {
		t.Fatalf("late MDA durable completion = %+v, %v", rec, err)
	}
}

func TestMDMSchedulerOldMDAResponseCannotBindReplacementConnection(t *testing.T) {
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
	}, mdaCommandDependencies("udid-mda-reconnect"))
	withoutLiveDispatcher(sch)
	old := schedulerTestProvider(t, srv, "old-mda-connection", "se-mda-reconnect")
	old.Mu().Lock()
	old.TrustLevel = registry.TrustHardware
	old.Mu().Unlock()
	oldGeneration := sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityRefresh)
	if oldGeneration != 1 {
		t.Fatalf("initial MDA registration generation = %d", oldGeneration)
	}
	sch.ChallengeSettled(old, false)
	startMDACommand(t, sch, "se-mda-reconnect", old, "udid-mda-reconnect", "old-mda-command")
	oldCandidate := sch.Candidate(verificationSchedulerKey("se-mda-reconnect", store.VerificationTaskMDA))
	if oldCandidate == nil || oldCandidate.BindingGen != oldGeneration {
		t.Fatal("old MDA command lost its registration generation")
	}

	replacement := schedulerTestProvider(
		t, srv, "new-mda-connection", "se-mda-reconnect",
	)
	sch.Submit(
		context.Background(), replacement.ID, replacement,
		store.VerificationPriorityRecovery,
	)
	if sch.ApplyLateMDA(
		"udid-mda-reconnect", "old-mda-command", [][]byte{{1}},
	) {
		t.Fatal("old MDA callback retained ownership after replacement connected")
	}
	old.Mu().Lock()
	oldVerified := old.MDAVerified
	old.Mu().Unlock()
	replacement.Mu().Lock()
	replacementVerified := replacement.MDAVerified
	replacement.Mu().Unlock()
	if oldVerified || replacementVerified {
		t.Fatalf("old MDA callback mutated proof state: old=%v replacement=%v", oldVerified, replacementVerified)
	}
}

func mdaCommandDependencies(udid string) mdmSchedulerDeps {
	return mdmSchedulerDeps{Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: func(ctx context.Context, _ mdmLiveBinding, kind store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		if kind == store.VerificationTaskSecurityInfo {
			return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true, UDID: udid}
		}
		<-ctx.Done()
		return mdmSchedulerAttemptResult{Outcome: store.VerificationOutcomeCancelled}
	}}
}

func startMDACommand(t *testing.T, sch *mdmVerificationScheduler, seKey string, provider *registry.Provider, udid, commandUUID string) {
	t.Helper()
	sch.StartWorkers()
	sch.DispatchDueRows()
	key := verificationSchedulerKey(seKey, store.VerificationTaskMDA)
	waitSchedulerCondition(t, func() bool {
		return sch.Candidate(key) != nil && sch.Status().Active[store.VerificationTaskSecurityInfo] == 0
	}, "SecurityInfo did not enqueue MDA")
	sch.DispatchDueRows()
	waitSchedulerCondition(t, func() bool { c := sch.Candidate(key); return c != nil && c.Running }, "MDA command attempt did not start")
	sch.ObserveAttemptCommand(provider, store.VerificationTaskMDA, udid, commandUUID)
}
