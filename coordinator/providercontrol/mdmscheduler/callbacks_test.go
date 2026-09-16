package mdmscheduler

import (
	"context"
	"crypto/sha256"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerObserveAttemptUDIDDoesNotDeadlock(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerHarness(t, Config{
		Workers: 1, QueueCapacity: 8,
	}, Dependencies{Now: func() time.Time { return now }})
	provider := schedulerProvider(t, srv, "observe", "se-observe")
	pending, err := st.UpsertVerificationJob(context.Background(), store.VerificationJob{
		SEPubKey: "se-observe", Serial: "serial-observe",
		Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending,
		Priority: store.VerificationPriorityRecovery, NextAttemptAt: now, UpdatedAt: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	claimed, ok, err := st.ClaimVerificationJob(
		context.Background(), pending.SEPubKey, pending.Kind,
		sch.owner, now, now.Add(time.Minute),
	)
	if err != nil || !ok {
		t.Fatalf("claim observe job: ok=%v err=%v", ok, err)
	}
	generation := sch.generation.Add(1)
	key := jobKey(claimed.SEPubKey, claimed.Kind)
	sch.mu.Lock()
	sch.bindings[claimed.SEPubKey] = &Binding{
		providerID: provider.ID, provider: provider,
		attestation: *provider.GetAttestationResult(),
		generation:  generation, ctx: context.Background(), challengeSettled: true,
	}
	sch.jobs[key] = &scheduledJob{
		record: claimed, bindingGen: generation, running: true,
	}
	sch.mu.Unlock()

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
	sch.mu.Lock()
	job := sch.jobs[key]
	udidOnly := job != nil && job.record.UDID == "udid-observe" &&
		job.callbackGen == 0 && job.callbackUUID == "" &&
		sch.byUDID["udid-observe"] == ""
	sch.mu.Unlock()
	if !udidOnly {
		t.Fatal("UDID observation created callback authority before command binding")
	}
	sch.ObserveAttemptCommand(
		provider, store.VerificationTaskSecurityInfo,
		"udid-observe", "command-observe",
	)
	sch.mu.Lock()
	exact := job.callbackGen == generation &&
		job.callbackUUID == "command-observe" &&
		sch.byUDID["udid-observe"] == key
	sch.mu.Unlock()
	if !exact {
		t.Fatal("command observation did not bind exact late-callback ownership")
	}
}

func TestMDMSchedulerHardUntrustAndLateSecurityInfoUseCurrentExactBinding(t *testing.T) {
	srv, _, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 8}, Dependencies{})
	old := schedulerProvider(t, srv, "late-old", "se-late")
	g1 := sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(old, false)
	sch.mu.Lock()
	key := jobKey("se-late", store.VerificationTaskSecurityInfo)
	sch.jobs[key].record.UDID = "udid-exact"
	sch.jobs[key].callbackGen = g1
	sch.jobs[key].callbackUUID = "old-command"
	sch.byUDID["udid-exact"] = key
	sch.mu.Unlock()

	newProvider := schedulerProvider(t, srv, "late-new", "se-late")
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
	sch.mu.Lock()
	sch.jobs[key].running = true
	sch.mu.Unlock()
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
	if binding == nil || binding.provider != newProvider {
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

func TestMDMSchedulerLateMDACompletesExactUDIDAndSEJob(t *testing.T) {
	srv, st, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 8}, Dependencies{})
	exact := schedulerProvider(t, srv, "late-mda-exact", "se-late-mda")
	other := schedulerProvider(t, srv, "late-mda-other", "se-other-mda")
	exact.Mu().Lock()
	exact.TrustLevel = registry.TrustHardware
	exact.Mu().Unlock()
	other.Mu().Lock()
	other.TrustLevel = registry.TrustHardware
	other.Mu().Unlock()
	mdaGeneration := sch.generation.Add(1)
	binding := Binding{
		providerID: exact.ID, provider: exact,
		attestation: *exact.GetAttestationResult(),
		generation:  mdaGeneration, ctx: context.Background(),
		challengeSettled: false, allowMDA: true,
	}
	sch.mu.Lock()
	sch.bindings["se-late-mda"] = &binding
	sch.mu.Unlock()
	sch.enqueueMDA(binding, "udid-late-mda")
	mdaKey := jobKey("se-late-mda", store.VerificationTaskMDA)
	sch.mu.Lock()
	sch.jobs[mdaKey].callbackGen = mdaGeneration
	sch.jobs[mdaKey].callbackUUID = "mda-command"
	sch.byUDID["udid-late-mda"] = mdaKey
	sch.mu.Unlock()
	freshness := sha256.Sum256([]byte("se-late-mda"))
	chain, root := mintMDALeafChain(t, "serial-late-mda-exact", freshness[:])
	restore := attestation.OverrideRootCAForTest(root)
	defer restore()
	if sch.ApplyLateMDA("different-udid", "mda-command", chain) {
		t.Fatal("late MDA attached without exact scheduler UDID ownership")
	}
	if !sch.ApplyLateMDA("udid-late-mda", "mda-command", chain) {
		t.Fatal("exact but unchallenged late MDA callback was not consumed and dropped")
	}
	exact.Mu().Lock()
	verifiedBeforeChallenge := exact.MDAVerified
	exact.Mu().Unlock()
	if verifiedBeforeChallenge {
		t.Fatal("late MDA granted before the current challenge settled")
	}
	sch.mu.Lock()
	sch.bindings["se-late-mda"].challengeSettled = true
	sch.mu.Unlock()
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
	srv, _, sch := newSchedulerHarness(t, Config{
		Workers: 1, QueueCapacity: 8,
	}, Dependencies{})
	old := schedulerProvider(t, srv, "old-mda-connection", "se-mda-reconnect")
	old.Mu().Lock()
	old.TrustLevel = registry.TrustHardware
	old.Mu().Unlock()
	oldGeneration := sch.generation.Add(1)
	binding := Binding{
		providerID: old.ID, provider: old,
		attestation: *old.GetAttestationResult(),
		generation:  oldGeneration, ctx: context.Background(),
		challengeSettled: true, allowMDA: true,
	}
	sch.mu.Lock()
	sch.bindings["se-mda-reconnect"] = &binding
	sch.mu.Unlock()
	sch.enqueueMDA(binding, "udid-mda-reconnect")
	mdaKey := jobKey("se-mda-reconnect", store.VerificationTaskMDA)
	sch.mu.Lock()
	sch.jobs[mdaKey].callbackGen = oldGeneration
	sch.jobs[mdaKey].callbackUUID = "old-mda-command"
	sch.byUDID["udid-mda-reconnect"] = mdaKey
	sch.mu.Unlock()

	replacement := schedulerProvider(
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
